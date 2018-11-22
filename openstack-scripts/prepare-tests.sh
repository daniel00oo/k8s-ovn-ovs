#!/bin/bash

set -e
set -x

set -o pipefail

K8S_MASTER_IP=""
ID_RSA=""

function configure-kubectl () {
    mkdir -p scp
    ssh -i $ID_RSA $K8S_MASTER_IP mkdir -p ~/scp
    ssh -i $ID_RSA $K8S_MASTER_IP sudo cp -r /etc/kubernetes/* ~/scp
    ssh -i $ID_RSA $K8S_MASTER_IP sudo cp /root/.kube/config ~/scp
    ssh -i $ID_RSA $K8S_MASTER_IP sudo chown -R ubuntu:ubuntu ~/scp
    scp -r -i $ID_RSA $K8S_MASTER_IP:~/scp/* scp/

    mkdir -p ~/.kube
    sudo mkdir -p /etc/kubernetes/tls

    cp ~/scp/config ~/.kube/
    sudo cp ~/scp/tls/* /etc/kubernetes/tls
    sudo chmod 0644 /etc/kubernetes/tls/*
}

function program-is-installed() {
    local return_=1
    type $1 >/dev/null 2>&1 || { local return_=0; }
    echo "$return_"
}

function install-docker(){
    if [[ $(program_is_installed docker) != "1" ]]; then
        echo "Installing docker"
        DEBIAN_FRONTEND=noninteractive sudo apt-get install docker.io -y

        echo "Adding user $USER to docker group"
        sudo usermod -a -G docker $USER
    fi
}

function build-k8s-parts () {
    sudo run-e2e/kubernetes/build/run.sh make WHAT="test/e2e/e2e.test  cmd/kubectl vendor/github.com/onsi/ginkgo/ginkgo"
}

function build-kubetest () {
    if [[ ! -d test-infra ]]; then
        git clone https://github.com/e2e-win/test-infra.git
    fi
    pushd test-infra
        export PATH="$PATH:$HOME/bin"
        bazel build //kubetest
        sudo cp bazel-bin/kubetest/linux_amd64_stripped/kubetest /usr/bin
    popd
}

function populate-kube-env () {
    sed -i "s/KUBE_MASTER=/&local/" run-e2e/kube-env
    sed -i "s/KUBE_MASTER_IP=/&$K8S_MASTER_IP/" run-e2e/kube-env
    sed -i "s/KUBE_MASTER_URL=/&https:\/\/$K8S_MASTER_IP/" run-e2e/kube-env
    sed -i "s/KUBECONFIG=/&\/home\/ubuntu\/.kube\/config/" run-e2e/kube-env
    sed -i "s/KUBE_TEST_REPO_LIST=/&\/home\/ubuntu\/run-e2e\/repo-list.yaml/" run-e2e/kube-env
}


function started() {
    local TIME=`date +%s`
    local GIT_VERSION=`git --version`
    #local PULL_REFS=1

    # making sure the tmp file exists and is empty
    touch tmp.json
    echo "" > tmp.json
    # fill it with the necessary info
    echo "{" >> tmp.json
    echo "\"timestamp\": $TIME," >> tmp.json
    echo "\"pull\": \"$PULL_REFS from the run\"," >> tmp.json
    echo "\"repos\": {" >> tmp.json
    echo "\"org/repo\": \"$GIT_VERSION\"" >> tmp.json
    echo "}" >> tmp.json
    echo "}" >> tmp.json

    jq . tmp.json > started.json
    rm tmp.json
}

function finished() {
    local TIME=`date +%s`
    local METADATA=$(cat artifacts/metadata.json)

    # make sure the temporary file exists and is empty
    touch tmp.json
    echo "" > tmp.json
    # fill it with the necessary info
    echo "{" >> tmp.json
    echo "\"timestamp\": $TIME," >> tmp.json
    if [[ $RESULT -eq 0 ]]; then
        echo "\"result\": \"SUCCESS\"," >> tmp.json
    else
        echo "\"result\": \"FAILURE\"," >> tmp.json
    fi
    echo "\"metadata\": $METADATA" >> tmp.json
    echo "}" >> tmp.json

    # sending it to the final file
    jq . tmp.json > finished.json
    # removing the temporary file
    rm tmp.json
}

function start-tests () {
    pushd run-e2e
        set -x
        source kube-env
        export KUBECTL_PATH=$(which kubectl)
        focus=$(cat focus)
        skip=$(cat skip)
        mkdir -p $HOME/results
        pushd kubernetes
            kubetest --ginkgo-parallel=4 --verbose-commands=true --provider=local --test \
                --test_args="--ginkgo.dryRun=false --ginkgo.focus=$(eval $focus) --ginkgo.skip=$(eval $skip)" --dump=$HOME/results/ \
                | tee $HOME/results/kubetest.log
        popd
    popd
}

function main () {
    TEMP=$(getopt -o i:k::d::a::p: --long k8s-master-ip:,id-rsa: -n '' -- "$@")
    if [[ $? -ne 0 ]]; then
        exit 1
    fi
    
    echo $TEMP
    eval set -- "$TEMP"
    
    while true ; do
        case "$1" in
            --k8s-master-ip)
                K8S_MASTER_IP="$2";    shift 2;;
            --id-rsa)
                ID_RSA="$2";           shift 2;;
            --) shift ; break ;;
        esac
    done

    configure-kubectl
    install-docker
    clone-k8s
    build-k8s-parts
    install-bazel
    build-kubetest
    populate-kube-env
    started
    start-tests
    finished
}

main "$@"
