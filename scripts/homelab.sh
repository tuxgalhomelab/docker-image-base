#!/usr/bin/env bash
set -E -e -o pipefail

# Enable verbose output of the lines in the script if requested.
if [[ "${HOMELAB_VERBOSE}" == "y" ]]; then
    set -x
fi

export DEBIAN_FRONTEND=noninteractive

base_install_dir="/opt"
deb_pkgs_dir="/deb-pkgs"

init() {
    local script_name="$(basename "$(realpath "${BASH_SOURCE[0]}")")"
    local script_parent_dir="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
    local script_abs_path="${script_parent_dir:?}/${script_name:?}"

    mkdir -p ${base_install_dir:?}/bin
    ln -sf ${script_abs_path:?} ${base_install_dir:?}/bin/homelab
}

destroy() {
    local script_name="$(basename "$(realpath "${BASH_SOURCE[0]}")")"
    local script_parent_dir="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
    local script_abs_path="${script_parent_dir:?}/${script_name:?}"

    rm -f ${base_install_dir:?}/bin/homelab
    rm -f ${script_abs_path}
}

update_repo() {
    # Refresh package list from the repository.
    apt-get update
}

install_packages() {
    apt-get install \
        --assume-yes \
        --no-install-suggests \
        --no-install-recommends \
        ${@}
}

remove_packages() {
    apt-get remove \
        --assume-yes \
        --purge \
        --allow-remove-essential \
        ${@}
}

cleanup_post_package_op() {
    # Remove any packages that are no longer required.
    apt-get remove --purge --auto-remove -y
    apt-get autoremove --assume-yes
    apt-get clean
    apt-get purge -y --auto-remove
    # Manually remove leftover cruft after having to run
    # an apt command.
    rm -rf \
        /var/lib/apt/lists/* \
        /tmp/* \
        /var/tmp/* \
        /var/cache/debconf/* \
        /var/cache/apt/archives \
        /var/cache/ldconfig/aux-cache \
        /var/log/apt/* \
        /var/log/*log \
        /usr/share/doc/* \
        /usr/share/doc-base/* \
        /usr/share/gcc/* \
        /usr/share/gdb/* \
        /usr/share/info/* \
        /usr/share/man/* \
        /usr/share/pixmaps*
}

install_go() {
    local google_linux_package_gpg_key="EB4C 1BFD 4F04 2F6D DDCC  EC91 7721 F63B D38B 4796"

    local go_version="${1:?}"
    local amd64_sha256_checksum="${2:?}"
    local arm64_sha256_checksum="${3:?}"
    local pkg_arch="$(dpkg --print-architecture)"

    # Install dependencies.
    update_repo
    install_packages gnupg

    # Download the release.
    mkdir -p /tmp/go-download
    download_file_to \
        https://go.dev/dl/go${go_version:?}.linux-${pkg_arch:?}.tar.gz \
        /tmp/go-download
    download_file_to \
        https://go.dev/dl/go${go_version:?}.linux-${pkg_arch:?}.tar.gz.asc \
        /tmp/go-download

    # Download the public keys for verification.
    gpg \
        --batch \
        --keyserver hkp://keyserver.ubuntu.com \
        --recv-keys "${google_linux_package_gpg_key:?}"

    # Download and validate the signatures of the packages.
    gpg \
        --verbose \
        --verify \
        /tmp/go-download/go${go_version:?}.linux-${pkg_arch:?}.tar.gz.asc
    if [[ "${pkg_arch:?}" == "amd64" ]]; then
        local go_sha256_checksum=${amd64_sha256_checksum:?};
    elif [[ "${pkg_arch:?}" == "arm64" ]]; then
        local go_sha256_checksum=${arm64_sha256_checksum:?};
    else
        echo "Unsupported arch ${pkg_arch:?} for checksum";
        exit 1;
    fi
    echo "${go_sha256_checksum:?} /tmp/go-download/go${go_version:?}.linux-${pkg_arch:?}.tar.gz" |\
        sha256sum -c

    # Unpack and install the release.
    tar -C /opt -xvf /tmp/go-download/go${go_version:?}.linux-${pkg_arch:?}.tar.gz

    # Setup misc directories.
    mkdir -p /go /go/src /go/bin

    # Clean up.
    rm -rf /tmp/go-download
    remove_packages gnupg
}

install_node() {
    local nvm_version="${1:?}"
    local nvm_sha256_checksum="${2:?}"
    local nodejs_version="${3:?}"

    install_tar_dist \
        https://github.com/nvm-sh/nvm/archive/refs/tags/${nvm_version:?}.tar.gz \
        ${nvm_sha256_checksum:?} \
        nvm \
        nvm-${nvm_version#"v"} \
        root \
        root
    source "/opt/nvm/nvm.sh"
    nvm install ${nodejs_version:?}
}

install_python() {
    update_repo
    install_packages \
        build-essential \
        libbz2-dev \
        libffi-dev \
        liblzma-dev \
        libncurses5-dev \
        libreadline-dev \
        libsqlite3-dev \
        libssl-dev \
        zlib1g-dev
    install_python_without_deps "$@"
}

install_python_without_deps() {
    local pyenv_version="${1:?}"
    local pyenv_sha256_checksum="${2:?}"
    local python_version="${3:?}"

    install_tar_dist \
        https://github.com/pyenv/pyenv/archive/refs/tags/${pyenv_version:?}.tar.gz \
        ${pyenv_sha256_checksum:?} \
        pyenv \
        pyenv-${pyenv_version#"v"} \
        root \
        root

    pushd /opt/pyenv && src/configure && make -C src && popd

    export PYENV_ROOT="/opt/pyenv"
    export PATH="${PYENV_ROOT}/shims:${PYENV_ROOT}/bin:${PATH}"
    eval "$(pyenv init -)"
    PYTHON_CONFIGURE_OPTS="--enable-optimizations --with-lto" \
        PYTHON_CFLAGS="-march=native -mtune=native" \
        PROFILE_TASK="-m test.regrtest --pgo -j0" \
        pyenv install ${python_version:?}
    pyenv global ${python_version:?}
}

configure_en_us_utf8_locale() {
    # Set up en_US.UTF-8 locale.
    sed -i -e 's/# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
    dpkg-reconfigure --frontend=noninteractive locales
    update-locale LANG=en_US.UTF-8
    echo "LC_ALL=en_US.UTF-8" >> /etc/environment
    echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
    echo "LANG=en_US.UTF-8" > /etc/locale.conf
    locale-gen en_US.UTF-8
    # Remove other locale files which we won't use.
    find /usr/share/i18n/locales ! -name en_US -type f -exec rm -v {} +
    find /usr/share/i18n/charmaps ! -name UTF-8.gz -type f -exec rm -v {} +
}

purge_locales() {
    # Purge existing locales.
    apt-get purge locales
}

setup_apt() {
    # Do not install recommended and suggested packages.
    echo 'APT::Install-Recommends "0" ; APT::Install-Suggests "0" ;' > \
        /etc/apt/apt.conf.d/01-no-recommended
    # Do not install these files as part of package installations.
    echo 'path-exclude=/usr/share/doc/*' > \
        /etc/dpkg/dpkg.cfg.d/path_exclusions
    echo 'path-exclude=/usr/share/groff/*' >> \
        /etc/dpkg/dpkg.cfg.d/path_exclusions
    echo 'path-exclude=/usr/share/info/*' >> \
        /etc/dpkg/dpkg.cfg.d/path_exclusions
    echo 'path-exclude=/usr/share/linda/*' >> \
        /etc/dpkg/dpkg.cfg.d/path_exclusions
    echo 'path-exclude=/usr/share/lintian/*' >> \
        /etc/dpkg/dpkg.cfg.d/path_exclusions
    echo 'path-exclude=/usr/share/man/*' >> \
        /etc/dpkg/dpkg.cfg.d/path_exclusions
}

arch_for_tuxgal_go_pkg() {
    local platform="$(uname -m)"
    case "${platform:?}" in
        "x86_64")
            echo "x86_64"
            ;;
        "i386"|"i686")
            echo "i386"
            ;;
        "armv7l"|"armhf")
            echo "armv7"
            ;;
        "arm"|"armel")
            echo "armv6"
            ;;
        "aarch64"|"armv8l")
            echo "arm64"
            ;;
        *)
            echo "Invalid command \"$1\""
            exit 1
    esac

}

install_picoinit() {
    local picoinit_version="0.3.0"
    install_tuxgal_go_package "tuxgal/picoinit" "${picoinit_version:?}"
}

install_tuxgal_go_package() {
    local tuxgal_gpg_key="1856E0777ADFF1E9"

    install_gpg
    download_gpg_key "hkps://keys.openpgp.org" "${tuxgal_gpg_key:?}"
    local download_dir="$(mktemp -d)"
    mkdir -p ${download_dir:?}

    local repo="${1:?}"
    local pkg_name="$(basename ${repo:?})"
    local version="${2:?}"
    local arch="$(arch_for_tuxgal_go_pkg)"
    local base_url="https://github.com/${repo:?}/releases/download/v${version:?}"
    local tar_url="${base_url:?}/${pkg_name:?}_${version:?}_Linux_${arch:?}.tar.xz"
    local tar_sig_url="${base_url:?}/${pkg_name:?}_${version:?}_Linux_${arch:?}.tar.xz.sig"
    local checksums_url="${base_url:?}/checksums.txt"
    local checksums_sig_url="${base_url:?}/checksums.txt.sig"

    echo "Downloading ${pkg_name:?} for \"${arch:?}\" v${version:?}"
    for url in "${tar_url:?}"  "${tar_sig_url:?}" "${checksums_url:?}" "${checksums_sig_url:?}"; do
        download_file_to "${url:?}" "${download_dir:?}"
    done

    pushd ${download_dir:?}
    gpg1 --verbose checksums.txt.sig
    gpg1 --verbose ${pkg_name:?}_${version:?}_Linux_${arch:?}.tar.xz.sig
    sha256sum --check --ignore-missing checksums.txt
    tar xvf ${pkg_name:?}_${version:?}_Linux_${arch:?}.tar.xz
    mkdir -p /opt/${pkg_name:?}
    mv ${pkg_name:?} /opt/${pkg_name:?}/
    ln -sf /opt/${pkg_name:?}/${pkg_name:?} /opt/bin/${pkg_name:?}
    popd

    rm -rf ${download_dir:?}
    cleanup_gpg
}

add_user() {
    local user_name=${1:?}
    local user_id=${2:?}
    local group_name=${3:?}
    local group_id=${4:?}
    local create_home_dir=""
    local system_user=""
    if [[ "$5" == "--create-home-dir" || "$6" == "--create-home-dir" ]]; then
        create_home_dir="--create-home"
    fi
    if [[ "$5" == "--system-user" || "$6" == "--system-user" ]]; then
        system_user="--system "
    fi
    groupadd --gid ${group_id:?} ${group_name:?}
    useradd \
        ${create_home_dir} \
        ${system_user} \
        --shell /bin/bash \
        --uid ${user_id:?} \
        --gid ${group_id:?} \
        ${user_name:?}
}

download_file() {
    local url="${1:?}"
    curl \
        --silent \
        --fail \
        --location \
        --show-error \
        ${url:?}
}

download_file_as() {
    local url="${1:?}"
    local dest_file="${2:?}"
    curl \
        --silent \
        --fail \
        --location \
        --show-error \
        --output "${dest_file:?}" \
        ${url:?}
}

download_file_to() {
    local url="${1:?}"
    local dest_dir="${2:?}"
    curl \
        --silent \
        --fail \
        --location \
        --show-error \
        --remote-name \
        --output-dir "${dest_dir:?}" \
        ${url:?}
}

install_tar_dist() {
    local download_url="${1:?}"
    local download_checksum="${2:?}"
    local package_name="${3:?}"
    local symlink_to="${4:?}"
    local owner_user="${5:?}"
    local owner_group="${6:?}"
    local install_dir="${base_install_dir:?}/${package_name:?}"
    local tar_file="/tmp/file-$(date +'%Y-%m-%d_%H-%M-%S.%3N')"

    # Prepare the install directory.
    rm -rf ${install_dir:?}
    mkdir -p ${base_install_dir:?}
    pushd ${base_install_dir:?} >/dev/null

    # Download and unpack the release.
    download_file_as "${download_url:?}" "${tar_file:?}"
    echo "${download_checksum:?} ${tar_file:?}" | sha256sum -c
    tar -xf ${tar_file:?}
    rm ${tar_file:?}

    # Set up symlinks.
    ln -s ${symlink_to:?} ${package_name:?}

    # Make the installed directory owned by the specified user and the group.
    chown -R ${owner_user:?}:${owner_group:?} ${install_dir:?}

    popd >/dev/null
}

install_bin() {
    local download_url="${1:?}"
    local download_checksum="${2:?}"
    local download_file_name="${3:?}"
    local package_name="${4:?}"
    local symlink_to="${5:?}"
    local owner_user="${6:?}"
    local owner_group="${7:?}"
    local install_dir="${base_install_dir:?}/${package_name:?}"
    local bin_file="/tmp/file-$(date +'%Y-%m-%d_%H-%M-%S.%3N')"

    # Prepare the install directory.
    rm -rf ${install_dir:?}
    mkdir -p ${install_dir:?}

    # Download and unpack the binary.
    download_file_as "${download_url:?}" "${bin_file:?}"
    echo "${download_checksum:?} ${bin_file:?}" | sha256sum -c
    chmod +x ${bin_file:?}
    mv ${bin_file:?} ${install_dir:?}/${download_file_name:?}

    # Set up symlinks.
    ln -s ${install_dir:?}/${download_file_name:?} ${symlink_to:?}

    # Make the installed directory owned by the specified user and the group.
    chown -R ${owner_user:?}:${owner_group:?} ${install_dir:?}
}

install_git_repo() {
    local git_repo_url="${1:?}"
    local git_branch_or_tag="${2:?}"
    local package_name="${3:?}"
    local symlink_to="${4:?}"
    local owner_user="${5:?}"
    local owner_group="${6:?}"
    local download_dir="${base_install_dir:?}/${symlink_to:?}"
    local install_dir="${base_install_dir:?}/${package_name:?}"

    # Download the git repository.
    download_git_repo \
        "${git_repo_url:?}" \
        "${git_branch_or_tag:?}" \
        "${download_dir:?}"

    # Set up symlinks.
    ln -s ${symlink_to:?} ${install_dir:?}

    # Make the installed directory owned by the specified user and the group.
    chown -R ${owner_user:?}:${owner_group:?} "${download_dir:?}" "${install_dir:?}"
}

download_git_repo() {
    local git_repo_url="${1:?}"
    local git_branch_or_tag="${2:?}"
    local download_dir="${3:?}"

    # Prepare the download directory.
    rm -rf ${download_dir:?}
    mkdir -p ${download_dir:?}

    # Clone the git repository.
    git clone \
        --quiet \
        --depth 1 \
        --branch ${git_branch_or_tag:?} \
        ${git_repo_url:?} \
        ${download_dir:?}
}

# Docker platform to uname arch mapping
# "linux/amd64"     "amd64"
# "linux/386"       "x86"
# "linux/arm64"     "aarch64"
# "linux/arm64/v8"  "aarch64"
# "linux/arm/v7"    "armhf", "armv7"
# "linux/arm/v6"    "arm"
# "linux/ppc64le"   "ppc64le"

export_gpg_key() {
    local keyserver="${1:?}"
    local gpg_key="${2:?}"
    local gpg_key_export_path="${3:?}"

    install_gpg
    download_gpg_key "${keyserver:?}" "${gpg_key:?}"
    gpg1 --export "${gpg_key:?}" > "${gpg_key_export_path:?}"
    cleanup_gpg
}

install_gpg() {
    install_packages gnupg1
}

download_gpg_key() {
    local keyserver="${1:?}"
    local gpg_key="${2:?}"

    echo "Fetching GPG key $gpg_key from $keyserver"
    gpg1 --verbose \
        --keyserver "$keyserver" \
        --keyserver-options timeout=10 \
        --recv-keys "${gpg_key:?}"
}

cleanup_gpg() {
    rm -rf "$HOME/.gnupg"
    remove_packages gnupg1
}

random_file_name() {
    shuf -zer -n10  {A..Z} {a..z} {0..9} | tr -d '\0'
}

# Build the packages locally for the specified debian source repo.
build_pkg_from_deb_src() {
    local src_repo="${1:?}"
    local pkgs="${2:?}"
    local dest_bin_repo_dir="${3:?}"
    local apt_repo_base_path="/etc/apt/sources.list.d"
    local src_repo_file="${apt_repo_base_path:?}/src_$(random_file_name).list"

    echo "${src_repo:?}" > ${src_repo_file:?}

    # Set up the destination directory cleanly.
    rm -rf "${dest_bin_repo_dir:?}"
    mkdir -p "${dest_bin_repo_dir:?}"
    # Ensure APT's "_apt" user can access the files.
    chmod 777 "${dest_bin_repo_dir:?}"
    # Save the list of currently-installed packages so build dependencies
    # can be cleanly removed later.
    local saved_apt_mark="$(apt-mark showmanual)"

    # Download the build dependencies.
    # Among the build dependencies, some packages depend on utilities
    # like getopt part of util-linux.
    update_repo
    install_packages util-linux
    apt-get build-dep -y ${pkgs:?}

    # Compile the target packages.
    pushd "${dest_bin_repo_dir:?}"
    DEB_BUILD_OPTIONS="nocheck parallel=$(nproc)" apt-get source --compile ${pkgs:?}
    popd

    # Remove the source repository as it is no longer needed.
    rm ${src_repo_file:?}

    # Reset apt-mark's "manual" list so that "purge --auto-remove" will
    # remove all the build dependencies. The purge is done as a last step.
    apt-mark showmanual | xargs apt-mark auto > /dev/null
    [ -z "$saved_apt_mark" ] || apt-mark manual $saved_apt_mark;

    # Create the local APT repo, that can be used to install this package from.
    # The dependency resolution will be handled by apt.
    pushd "${dest_bin_repo_dir:?}"
    dpkg-scanpackages . > Packages
    popd
    grep '^Package: ' "${dest_bin_repo_dir:?}/Packages"

    # Remove the packages installed just for the build.
    remove_packages util-linux
}

# Install the specified packages from the specified local repo directory.
install_locally_built_deb_pkg() {
    local bin_repo_dir="${1:?}"
    local pkgs="${2:?}"
    local apt_repo_base_path="/etc/apt/sources.list.d"
    local bin_repo_file="${apt_repo_base_path:?}/bin_$(random_file_name).list"

    echo "deb [ trusted=yes ] file://${bin_repo_dir:?} ./" > ${bin_repo_file:?}

    # Work around the following APT issue by using "Acquire::GzipIndexes=false"
    # (overriding "/etc/apt/apt.conf.d/docker-gzip-indexes")
    #   Could not open file /var/lib/apt/lists/partial/_tmp_tmp.ODWljpQfkE_._Packages - open (13: Permission denied)
    #   ...
    #   E: Failed to fetch store:/var/lib/apt/lists/partial/_tmp_tmp.ODWljpQfkE_._Packages  Could not open file /var/lib/apt/lists/partial/_tmp_tmp.ODWljpQfkE_._Packages - open (13: Permission denied)
    apt-get -o Acquire::GzipIndexes=false update

    # Install the target packages, which will use the .deb packages that we
    # just built and published to the local repository.
    install_packages ${pkgs:?}

    # Remove the binary repository.
    rm -rf ${bin_repo_file:?}
}

build_pkg_from_std_deb_src() {
    local pkgs="${1:?}"
    local apt_repo_base_path="/etc/apt/sources.list.d"
    local src_repo_file="${apt_repo_base_path:?}/src_$(random_file_name).sources"
    local build_dir="$(mktemp -d)"

    local debian_release="$(dpkg --status tzdata | awk -F'[:-]' '$1=="Provides"{print $NF}')"
    local main_src_repo="Types: deb-src\nURIs: http://deb.debian.org/debian\nSuites: ${debian_release:?} ${debian_release:?}-updates\nComponents: main contrib non-free\nSigned-By: /usr/share/keyrings/debian-archive-keyring.gpg"
    local security_src_repo="Types: deb-src\nURIs: http://deb.debian.org/debian-security\nSuites: ${debian_release:?}-security\nComponents: main contrib non-free\nSigned-By: /usr/share/keyrings/debian-archive-keyring.gpg"

    echo -e "${main_src_repo:?}\n\n${security_src_repo:?}\n\n" > \
        ${src_repo_file:?}

    # Ensure APT's "_apt" user can access the files.
    chmod 777 "${build_dir:?}"

    # Download the build dependencies.
    # Among the build dependencies, some packages depend on utilities
    # like getopt part of util-linux.
    update_repo
    install_packages util-linux
    apt-get build-dep -y ${pkgs:?}

    pushd "${build_dir:?}"

    # Download the sources for the target packages.
    DEB_BUILD_OPTIONS="nocheck parallel=$(nproc)" apt-get source ${pkgs:?}
    # Apply any available patches.
    mkdir -p /patches/
    find /patches -iname *.diff -print0 | sort -z | xargs -0 -r -n 1 patch -p1 -i
    # Build the target packages with the patches.
    DEB_BUILD_OPTIONS="nocheck parallel=$(nproc)" apt-get source --compile ${pkgs:?}
    # Move the resulting *.deb files.
    mkdir -p ${deb_pkgs_dir:?}
    mv *.deb "${deb_pkgs_dir:?}/"

    popd
}

install_deb_pkg() {
    local arch=$(dpkg --print-architecture)
    set -- "${@/#/${deb_pkgs_dir}/}"
    set -- "${@/%/_${arch:?}.deb}"
    install_packages ${@}
}

healthcheck_service() {
    local service_url="${1:?}"
    curl \
        --silent \
        --fail \
        --location \
        --show-error \
        --insecure \
        "${service_url:?}"
}

case "$1" in
    "setup")
        init
        setup_apt
        update_repo
        purge_locales
        install_packages "${@:2}"
        install_picoinit
        cleanup_post_package_op
        ;;
    "destroy")
        destroy
        ;;
    "cleanup")
        cleanup_post_package_op
        ;;
    "install")
        update_repo
        install_packages "${@:2}"
        cleanup_post_package_op
        ;;
    "remove")
        update_repo
        remove_packages "${@:2}"
        cleanup_post_package_op
        ;;
    "install-tuxgal-go-package")
        update_repo
        install_tuxgal_go_package "${@:2}"
        ;;
    "setup-en-us-utf8-locale")
        configure_en_us_utf8_locale
        ;;
    "add-user")
        add_user "${@:2}"
        ;;
    "download-file")
        download_file "${@:2}"
        ;;
    "download-file-as")
        download_file_as "${@:2}"
        ;;
    "download-file-to")
        download_file_to "${@:2}"
        ;;
    "install-tar-dist")
        install_tar_dist "${@:2}"
        ;;
    "install-bin")
        install_bin "${@:2}"
        ;;
    "install-git-repo")
        install_git_repo "${@:2}"
        ;;
    "download-git-repo")
        download_git_repo "${@:2}"
        ;;
    "export-gpg-key")
        update_repo
        export_gpg_key "${@:2}"
        cleanup_post_package_op
        ;;
    "build-pkg-from-deb-src")
        build_pkg_from_deb_src "${@:2}"
        cleanup_post_package_op
        ;;
    "install-locally-built-deb-pkg")
        install_locally_built_deb_pkg "${@:2}"
        cleanup_post_package_op
        ;;
    "build-pkg-from-std-deb-src")
        build_pkg_from_std_deb_src "${@:2}"
        cleanup_post_package_op
        ;;
    "install-deb-pkg")
        install_deb_pkg "${@:2}"
        cleanup_post_package_op
        ;;
    "install-go")
        install_go "${@:2}"
        cleanup_post_package_op
        ;;
    "install-node")
        install_node "${@:2}"
        cleanup_post_package_op
        ;;
    "install-python")
        install_python "${@:2}"
        cleanup_post_package_op
        ;;
    "install-python-without-deps")
        install_python_without_deps "${@:2}"
        cleanup_post_package_op
        ;;
    "healthcheck-service")
        healthcheck_service "${@:2}"
        ;;
    *)
        echo "Invalid command \"$1\""
        exit 1
esac
