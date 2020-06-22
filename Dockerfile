# Copyright 2018 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
FROM ubuntu:18.04 as base_build

ARG TF_SERVING_VERSION_GIT_BRANCH=master
ARG TF_SERVING_VERSION_GIT_COMMIT=head

LABEL maintainer="Karthik Vadla <karthik.vadla@intel.com>"
LABEL tensorflow_serving_github_branchtag=${TF_SERVING_VERSION_GIT_BRANCH}
LABEL tensorflow_serving_github_commit=${TF_SERVING_VERSION_GIT_COMMIT}

RUN echo deb http://mirrors.aliyun.com/ubuntu/ bionic main restricted universe > /etc/apt/sources.list
RUN echo deb-src http://mirrors.aliyun.com/ubuntu/ bionic main restricted universe >> /etc/apt/sources.list
RUN echo deb http://mirrors.aliyun.com/ubuntu/ bionic-security main restricted universe >> /etc/apt/sources.list
RUN echo deb-src http://mirrors.aliyun.com/ubuntu/ bionic-security main restricted universe >> /etc/apt/sources.list
RUN echo deb http://mirrors.aliyun.com/ubuntu/ bionic-updates main restricted universe >> /etc/apt/sources.list
RUN echo deb-src http://mirrors.aliyun.com/ubuntu/ bionic-updates main restricted universe >> /etc/apt/sources.list
RUN echo deb http://mirrors.aliyun.com/ubuntu/ bionic-proposed main restricted universe >> /etc/apt/sources.list
RUN echo deb-src http://mirrors.aliyun.com/ubuntu/ bionic-proposed main restricted universe >> /etc/apt/sources.list
RUN echo deb http://mirrors.aliyun.com/ubuntu/ bionic-backports main restricted universe >> /etc/apt/sources.list
RUN echo deb-src http://mirrors.aliyun.com/ubuntu/ bionic-backports main restricted universe >> /etc/apt/sources.list

RUN apt-get update && apt-get install -y --no-install-recommends \
        automake \
        build-essential \
        ca-certificates \
        curl \
        git \
        libcurl3-dev \
        libfreetype6-dev \
        libpng-dev \
        libtool \
        libzmq3-dev \
        mlocate \
        openjdk-8-jdk\
        openjdk-8-jre-headless \
        pkg-config \
        python-dev \
        software-properties-common \
        swig \
        unzip \
        wget \
        zip \
        zlib1g-dev \
        python3-distutils \
        && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Install python 3.6.
RUN add-apt-repository ppa:deadsnakes/ppa && \
    apt-get update && apt-get install -y \
    python3.6 python3.6-dev python3-pip python3.6-venv && \
    rm -rf /var/lib/apt/lists/* && \
    python3.6 -m pip install pip --upgrade && \
    update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.6 0

# Make python3.6 the default python version
RUN update-alternatives --install /usr/bin/python python /usr/bin/python3.6 0

RUN curl -fSsL -O https://bootstrap.pypa.io/get-pip.py && \
    python3 get-pip.py && \
    rm get-pip.py

RUN pip3 --no-cache-dir install \
    future>=0.17.1 \
    grpcio \
    h5py \
    keras_applications>=1.0.8 \
    keras_preprocessing>=1.1.0 \
    mock \
    numpy \
    requests \
    --ignore-installed six>=1.12.0

# Set up Bazel
ENV BAZEL_VERSION 3.0.0
WORKDIR /
RUN mkdir /bazel && \
    cd /bazel && \
    curl -H "User-Agent: Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/57.0.2987.133 Safari/537.36" -fSsL -O https://github.com/bazelbuild/bazel/releases/download/$BAZEL_VERSION/bazel-$BAZEL_VERSION-installer-linux-x86_64.sh && \
    curl -H "User-Agent: Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/57.0.2987.133 Safari/537.36" -fSsL -o /bazel/LICENSE.txt https://raw.githubusercontent.com/bazelbuild/bazel/master/LICENSE && \
    chmod +x bazel-*.sh && \
    ./bazel-$BAZEL_VERSION-installer-linux-x86_64.sh && \
    cd / && \
    rm -f /bazel/bazel-$BAZEL_VERSION-installer-linux-x86_64.sh

# Download TF Serving sources (optionally at specific commit).
WORKDIR /tensorflow-serving
RUN git clone --branch=${TF_SERVING_VERSION_GIT_BRANCH} https://github.com/tensorflow/serving . && \
    git remote add upstream https://github.com/tensorflow/serving.git && \
    if [ "${TF_SERVING_VERSION_GIT_COMMIT}" != "head" ]; then git checkout ${TF_SERVING_VERSION_GIT_COMMIT} ; fi

FROM base_build as binary_build

# Build, and install TensorFlow Serving
ARG TF_SERVING_BUILD_OPTIONS="--config=mkl --config=release"
RUN echo "Building with build options: ${TF_SERVING_BUILD_OPTIONS}"

ARG TF_SERVING_BAZEL_OPTIONS=""
RUN echo "Building with Bazel options: ${TF_SERVING_BAZEL_OPTIONS}"

RUN bazel build --color=yes --curses=yes \
    ${TF_SERVING_BAZEL_OPTIONS} \
    --verbose_failures \
    --output_filter=DONT_MATCH_ANYTHING \
    ${TF_SERVING_BUILD_OPTIONS} \
    tensorflow_serving/model_servers:tensorflow_model_server && \
    cp bazel-bin/tensorflow_serving/model_servers/tensorflow_model_server \
    /usr/local/bin/

# Build and install TensorFlow Serving API
RUN bazel build --color=yes --curses=yes \
    ${TF_SERVING_BAZEL_OPTIONS} \
    --verbose_failures \
    --output_filter=DONT_MATCH_ANYTHING \
    ${TF_SERVING_BUILD_OPTIONS} \
    tensorflow_serving/tools/pip_package:build_pip_package && \
    bazel-bin/tensorflow_serving/tools/pip_package/build_pip_package \
    /tmp/pip && \
    pip --no-cache-dir install --upgrade /tmp/pip/tensorflow_serving*.whl && \
    rm -rf /tmp/pip

# Copy MKL libraries
RUN cp /root/.cache/bazel/_bazel_root/*/external/mkl_linux/lib/* /usr/local/lib

ENV LIBRARY_PATH '/usr/local/lib:$LIBRARY_PATH'
ENV LD_LIBRARY_PATH '/usr/local/lib:$LD_LIBRARY_PATH'

FROM binary_build as clean_build
# Clean up Bazel cache when done.
RUN bazel clean --expunge --color=yes && \
    rm -rf /root/.cache
CMD ["/bin/bash"]
