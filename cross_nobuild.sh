#!/bin/bash -e

echo "=== cross_nobuild.sh revision 20261125d (root + chroot, hook-generated initramfs) ===" >&2

# The script runs as real root. After the bootstrap stage (which installs the
# base system via the host static pacman), every further pacman run happens
# INSIDE the chroot, so alpm hooks and scriptlets execute natively in the
# target and the initramfs (booster or mkinitcpio) is generated there too.

# functions
help() {
    echo '
Build ArchLinux ARM images. Must run as root (sudo). Host arch is auto-detected:
x86_64 hosts cross-build (archlinuxcn static pacman), aarch64 hosts build natively (Manjaro ARM static pacman).
After the bootstrap stage the script chroots into the target rootfs, so all
packages, alpm hooks and the initramfs generation (booster or mkinitcpio) run
natively inside the target. On an x86_64 host qemu-user-static with binfmt_misc
must be installed for the chroot to work.

./cross_nobuild.sh

  --install <pkg>           install the package into target image, can be specified multiple times
  --install-kernel <pkg>    install the kernel package into target image, also create booting configurations
  --install-kernel-pkg <url|path>  download (if URL) a .pkg.tar.zst kernel package and install it with pacman -U, can be specified multiple times
  --install-local-pkg <url|path>   download (if URL) a .pkg.tar.zst package and install it with pacman -U, no boot config, can be specified multiple times
  --install-bootstrap <pkg> install the package into target image at bootstrap stage, can be specified multiple times
  --uuid-root <uuid>        uuid to be used for root ext4 fs
  --uuid-boot <uuid>        uuid to be used for boot fat32 fs, only first 8 chars used
  --build-id <id>           a string id for the build
  --local-mirror            download pkgs from a local pacoloco mirror
  --help                    print this message and early quit

WARNING: CLI arguments are mostly for internal usage, you should not rely on its behaviour
WARNING: This script is written for Ubuntu22.04, the exact environment that Github Actions provide
'
}
dl() { # 1: url 2: output
    echo "Downloading '$2' <= '$1'" >&2
    if [[ "$2" ]]; then
        curl -qgb "" -fL --retry 3 --retry-delay 3 -o "$2" "$1"
    else
        curl -qgb "" -fL --retry 3 --retry-delay 3 "$1"
    fi
    echo "Downloaded '$2' <= '$1'" >&2
}

dump_binary_from_repo() { # 1: repo url, 2: repo name, 3: pkgname, 4: local bin, 5: source bin
    dl "$1/$2".db cache/repo.db
    local desc=$(tar -xOf cache/repo.db --wildcards "$3"'-*/desc')
    local names=($(sed -n '/%NAME%/{n;p;}' <<< "${desc}"))
    case ${#names[@]} in
    0)
        echo "Failed to find package '$3' in repo '$1"
        return 1
    ;;
    1)
        local ver=$(sed -n '/%VERSION%/{n;p;}' <<< "${desc}")
        local pkg=$(sed -n '/%FILENAME%/{n;p;}' <<< "${desc}")
    ;;
    *)
        local vers=($(sed -n '/%VERSION%/{n;p;}' <<< "${desc}"))
        local pkgs=($(sed -n '/%FILENAME%/{n;p;}' <<< "${desc}"))
        local id=0
        local name
        for name in "${names[@]}"; do
            if [[ "${name}" == "$3" ]]; then
                break
            fi
            local id=$(( id + 1 ))
        done
        local ver="${vers[${id}]}"
        local pkg="${pkgs[${id}]}"
    ;;
    esac
    if [[ ! -f bin/"$4-${ver}" ]]; then
        rm bin/"$4"-* || true
        dl "$1/${pkg}" cache/"${pkg}"
        tar -xOf cache/"${pkg}" "$5" > bin/"$4-${ver}".temp
        mv bin/"$4-${ver}"{.temp,}
    fi
    chmod +x bin/"$4-${ver}"
    ln -sf "$4-${ver}" bin/"$4"
}

unmount_root_all() {
    # Detach every mount created under cache/root, then the tmpfs root itself.
    # cache/root is a mount point (mount_root() mounts a tmpfs there), so it
    # MUST be unmounted before rm -rf, otherwise rm fails with
    # "Device or resource busy" even though no process is actually using it.
    umount --lazy cache/root/etc/resolv.conf 2>/dev/null || true
    umount --lazy cache/root/proc 2>/dev/null || true
    local node
    for node in full null random tty urandom zero pts; do
        umount --lazy cache/root/dev/"${node}" 2>/dev/null || true
    done
    # Clean unmount first, lazy detach as a fallback if something in the
    # chroot still holds the mount. Either way the mount point is gone before
    # we try to remove the directory.
    umount cache/root 2>/dev/null || umount --lazy cache/root 2>/dev/null || true
}

cleanup_build() {
    echo "=> Cleaning up before exiting..."
    umount_root_sub || true
    unmount_root_all || true
    rm -rf cache/root
}

pacman_could_retry() { # host-side static pacman, only used for the bootstrap stage
    echo ">>> [$(date -u +%H:%M:%S)] pacman BEGIN: $*" >&2
    if ! timeout 900 bin/pacman "$@"; then
        echo ">>> [$(date -u +%H:%M:%S)] pacman FAILED/TIMEOUT, retry once: $*" >&2
        timeout 900 bin/pacman "$@"
    fi
    echo ">>> [$(date -u +%H:%M:%S)] pacman END: $*" >&2
}

pacman_chroot() { # pacman inside the target rootfs, hooks run natively there
    echo ">>> [$(date -u +%H:%M:%S)] chroot pacman BEGIN: $*" >&2
    if ! timeout 1800 chroot cache/root pacman "$@"; then
        echo ">>> [$(date -u +%H:%M:%S)] chroot pacman FAILED/TIMEOUT, retry once: $*" >&2
        timeout 1800 chroot cache/root pacman "$@"
    fi
    echo ">>> [$(date -u +%H:%M:%S)] chroot pacman END: $*" >&2
}

get_uid_gid() {
    uid=$(id --user)
    gid=$(id --group)
}

check_identity_root() {
    get_uid_gid
    if [[ "${uid}" != 0 ]]; then
        echo "ERROR: Must run as root (UID = 0)"
        exit 1
    fi
    if [[ "${gid}" != 0 ]]; then
        echo "ERROR: Must run as GID = 0"
        exit 1
    fi
}

config_repos() {
    # Prebuilt static pacman for the host. x86_64 comes from archlinuxcn.
    # aarch64 has no prebuild in archlinuxcn/ALARM, but Manjaro ARM ships
    # one, which enables building natively on an aarch64 host (no qemu).
    mirror_pacman_static=${mirror_pacman_static:-https://ftp.tsukuba.wide.ad.jp/manjaro/arm-stable/core}
    if [[ "${pkg_from_local_mirror}" ]]; then
        mirror_archlinux=${mirror_archlinux:-http://repo.lan:9129/repo/archlinux}
        mirror_archlinuxarm=${mirror_alarm:-http://repo.lan:9129/repo/archlinuxarm}
        mirror_archlinuxcn=${mirror_archlinuxcn:-http://repo.lan:9129/repo/archlinuxcn_x86_64}
        mirror_7Ji=${mirror_7Ji:-http://repo.lan/7Ji}
    else
        mirror_archlinux=${mirror_archlinux:-https://geo.mirror.pkgbuild.com}
        mirror_archlinuxarm=${mirror_alarm:-http://mirror.archlinuxarm.org}
        if ping -w1 google.com &>/dev/null; then
            mirror_archlinuxcn=${mirror_archlinuxcn:-https://mirrors.xtom.us/archlinuxcn}
        else
            mirror_archlinuxcn=${mirror_archlinuxcn:-https://mirrors.tuna.tsinghua.edu.cn/archlinuxcn}
        fi
        mirror_7Ji=${mirror_7Ji:-https://github.com/7Ji/archrepo/releases/download}
    fi
    # Host pacman: on aarch64 hosts build natively with Manjaro ARM's static
    # pacman; on x86_64 hosts cross-build with archlinuxcn's static pacman.
    if [[ "$(uname -m)" == 'aarch64' ]]; then
        repo_url_pacman_host="${mirror_pacman_static}"/aarch64
        repo_name_pacman_host=core
    else
        repo_url_archlinuxcn_x86_64="${mirror_archlinuxcn}"/x86_64
        repo_url_pacman_host="${repo_url_archlinuxcn_x86_64}"
        repo_name_pacman_host=archlinuxcn
    fi
    # For base system packages
    repo_url_alarm_aarch64="${mirror_archlinuxarm}"/aarch64/'$repo'
    # For kernels and other stuffs
    repo_url_7Ji_aarch64="${mirror_7Ji}"/aarch64
}

prepare_host_dirs() {
    # Defensive umounts in case a previous run died without cleaning up
    umount --lazy cache/root/proc cache/root/dev/pts cache/root/etc/resolv.conf cache/root 2>/dev/null || true
    rm -rf cache
    mkdir -p {bin,cache/root,out,src/pkg}
}

prepare_pacman_static() {
    dump_binary_from_repo "${repo_url_pacman_host}" "${repo_name_pacman_host}" pacman-static pacman usr/bin/pacman-static
}

mount_root() {
    mount tmpfs-root cache/root -t tmpfs -o mode=0755,nosuid
    mkdir -p cache/root/{boot,dev/{pts,shm},etc/pacman.d,etc/pacman.d/gnupg,proc,run,sys/module,tmp,var/{cache/pacman/pkg,lib/pacman,log}}
    chmod 1777 cache/root/{dev/shm,tmp}
    chmod 555 cache/root/{proc,sys}
    mount proc cache/root/proc -t proc -o nosuid,noexec,nodev
    mount devpts cache/root/dev/pts -t devpts -o mode=0620,gid=5,nosuid,noexec
    for node in full null random tty urandom zero; do
        devnode=cache/root/dev/"${node}"
        touch "${devnode}"
        mount /dev/"${node}" "${devnode}" -o bind
    done
    ln -s /proc/self/fd/2 cache/root/dev/stderr
    ln -s /proc/self/fd/1 cache/root/dev/stdout
    ln -s /proc/self/fd/0 cache/root/dev/stdin
    ln -s /proc/kcore cache/root/dev/core
    ln -s /proc/self/fd cache/root/dev/fd
    ln -s pts/ptmx cache/root/dev/ptmx
    ln -s $(readlink -f /dev/stdout) cache/root/dev/console
}

umount_root_sub() {
    chroot cache/root killall -s KILL gpg-agent dirmngr || true
    for node in full null random tty urandom zero pts; do
        umount --lazy cache/root/dev/"${node}" 2>/dev/null || true
    done
    umount --lazy cache/root/proc 2>/dev/null || true
    rm -rf cache/root/sys/module cache/root/dev/*
}

prepare_pacman_configs() {
    # Host-side pacman config, only used for the bootstrap stage (the root is
    # empty then, so it cannot run pacman itself yet). Afterwards the target's
    # own /etc/pacman.conf takes over, see prepare_chroot_pacman().
    pacman_config="
RootDir      = cache/root
DBPath       = cache/root/var/lib/pacman/
CacheDir     = src/pkg/
LogFile      = cache/root/var/log/pacman.log
GPGDir       = cache/root/etc/pacman.d/gnupg/
HookDir      = cache/root/etc/pacman.d/hooks/
Architecture = aarch64"
    pacman_mirrors="
[core]
Server = ${repo_url_alarm_aarch64}
[extra]
Server = ${repo_url_alarm_aarch64}
[alarm]
Server = ${repo_url_alarm_aarch64}
[aur]
Server = ${repo_url_alarm_aarch64}
[7Ji]
Server = ${repo_url_7Ji_aarch64}"

    echo "[options]${pacman_config}
SigLevel = Never${pacman_mirrors}" > cache/pacman-loose.conf
}

prepare_chroot_pacman() {
    # Write the target's own pacman config. All subsequent pacman runs happen
    # inside the chroot with this config, so hooks and scriptlets execute
    # natively in the target arch.
    cat > cache/root/etc/pacman.conf <<EOF
[options]
HoldPkg      = pacman glibc
Architecture = aarch64
SigLevel = DatabaseOptional

[core]
Server = ${repo_url_alarm_aarch64}
[extra]
Server = ${repo_url_alarm_aarch64}
[alarm]
Server = ${repo_url_alarm_aarch64}
[aur]
Server = ${repo_url_alarm_aarch64}
[7Ji]
Server = ${repo_url_7Ji_aarch64}
EOF
    # For installing local .pkg.tar.zst files that carry no detached signature
    sed 's/^SigLevel = .*/SigLevel = Never/' cache/root/etc/pacman.conf > cache/root/etc/pacman-local.conf
    # chroot pacman downloads packages itself, give it DNS
    enable_network
}

enable_network() {
    cat /etc/resolv.conf > cache/resolv.conf
    # resolv.conf in a fresh ALARM root is a symlink into /run, replace it
    # with a plain file so the bind mount below has a real target
    rm -f cache/root/etc/resolv.conf
    touch cache/root/etc/resolv.conf
    mount cache/resolv.conf cache/root/etc/resolv.conf -o bind
}

disable_network() {
    umount cache/root/etc/resolv.conf 2>/dev/null || true
}

bootstrap_root() {
    pacman_could_retry -Sy --config cache/pacman-loose.conf --noconfirm "${install_pkgs_bootstrap[@]}"
    enable_network
    rm -rf cache/root/etc/pacman.d/gnupg
    # GnuPG > 2.4.3-2 does not like SHA1 only key, which is what ALARM Builder uses
    # :-( Sigh, let's lsign the key manually to give it full trust
    chroot cache/root /bin/bash -c "pacman-key --init && pacman-key --populate && pacman-key --lsign 68B3537F39A313B3E574D06777193F152BDBE6A6"
    disable_network
}

install_initramfs() {
    # Install the chosen provider BEFORE the kernel. Every kernel package
    # depends on the virtual "initramfs" package; with the provider already
    # installed, pacman won't pull in the other one. The alpm hook then builds
    # the images automatically while the kernel is installed (standard Arch
    # behaviour), running natively here in the chroot.
    if [[ "${initramfs}" == 'booster' ]]; then
        # booster's install hook runs regenerate_images -> `find /usr/lib/modules`.
        # No kernel is present yet, so create the directory to keep that hook
        # happy. booster.yaml must exist before the kernel lands, because that
        # is when the hook actually generates the images.
        mkdir -p cache/root/usr/lib/modules
        printf '%s: %s\n' \
            'universal' 'true' > cache/root/etc/booster.yaml
        pacman_chroot --needed --noconfirm -S booster
    else
        pacman_chroot --needed --noconfirm -S mkinitcpio
        # Temporary hack before https://gitlab.archlinux.org/archlinux/mkinitcpio/mkinitcpio/-/issues/218 is resolved.
        # Must run before the kernel lands, since that is when the hook reads
        # mkinitcpio.conf to build the images.
        sed -i 's/ kms / /' cache/root/etc/mkinitcpio.conf
    fi
}

setup_initramfs() {
    # The alpm hook generated the images during kernel installation. This
    # stage only normalizes booster's image names (it may use the kernel
    # release instead of pkgbase), makes sure vmlinuz is in /boot (booster's
    # hook does not do that), and regenerates explicitly if an image is
    # missing for any reason.
    [[ ${#install_pkgs_kernel[@]} == 0 ]] && return
    local vmlinuz kbase kernel img stem known regenerated=
    for vmlinuz in cache/root/usr/lib/modules/*/vmlinuz; do
        [[ -e "${vmlinuz}" ]] || continue
        kbase=$(cat "${vmlinuz%/vmlinuz}/pkgbase" 2>/dev/null) || kbase=
        [[ -n "${kbase}" ]] || continue
        [[ -e cache/root/boot/vmlinuz-"${kbase}" ]] || \
            cp "${vmlinuz}" cache/root/boot/vmlinuz-"${kbase}"
    done
    if [[ "${initramfs}" == 'booster' ]]; then
        for img in cache/root/boot/booster-*.img; do
            [[ -e "${img}" ]] || continue
            stem=$(basename "${img}")
            stem=${stem#booster-}
            stem=${stem%.img}
            known=
            for kernel in "${install_pkgs_kernel[@]}"; do
                [[ "${stem}" == "${kernel}" ]] && known='yes' && break
            done
            [[ -n "${known}" ]] && continue
            for kernel in "${install_pkgs_kernel[@]}"; do
                if [[ ! -f cache/root/boot/booster-"${kernel}".img ]]; then
                    mv "${img}" cache/root/boot/booster-"${kernel}".img
                    echo "=> Renamed $(basename "${img}") -> booster-${kernel}.img"
                    break
                fi
            done
        done
        for kernel in "${install_pkgs_kernel[@]}"; do
            [[ -f cache/root/boot/booster-"${kernel}".img && -z "${regenerated}" ]] || continue
            echo "=> booster image for '${kernel}' missing, regenerating in chroot"
            chroot cache/root /usr/lib/booster/regenerate_images
            regenerated='yes'
        done
        for kernel in "${install_pkgs_kernel[@]}"; do
            [[ -f cache/root/boot/booster-"${kernel}".img ]] || \
                echo "WARNING: booster image for '${kernel}' not found in /boot"
        done
    else
        for kernel in "${install_pkgs_kernel[@]}"; do
            [[ -f cache/root/boot/initramfs-"${kernel}"-fallback.img ]] && continue
            echo "=> initramfs for '${kernel}' missing, regenerating in chroot"
            chroot cache/root mkinitcpio -P
            break
        done
        for kernel in "${install_pkgs_kernel[@]}"; do
            [[ -f cache/root/boot/initramfs-"${kernel}"-fallback.img ]] || \
                echo "WARNING: initramfs for '${kernel}' not found in /boot"
        done
    fi
}

setup_extlinux() {
    # Setup configuration
    local conf=cache/extlinux.conf
    echo "MENU TITLE Select the kernel to boot
TIMEOUT 30
DEFAULT ${install_pkgs_kernel[0]}" > "${conf}"
    local kernel conf_{linux,initrd,fdt,append}
    local has_uenv=
    for kernel in "${install_pkgs_kernel[@]}"; do
        conf_linux="vmlinuz-${kernel}"
        if [[ "${initramfs}" == 'booster' ]]; then
            conf_initrd="booster-${kernel}.img"
        else
            conf_initrd="initramfs-${kernel}-fallback.img"
        fi
        conf_fdtdir="dtbs/${kernel}"
        conf_fdt="dtbs/${kernel}/amlogic/PLEASE_SET_YOUR_DTB_AND_UNCOMMENT_THIS_LINE_AND_COMMENT_FDTDIR.dtb"
        conf_append="root=UUID=${uuid_root} rw audit=0 apt_blkdevs=mmcblk2"
        printf \
            "LABEL\t%s\n\tLINUX\t/%s\n\tINITRD\t/%s\n\tFDTDIR\t/%s\n\t#FDT\t/%s\n\tAPPEND\t%s\n" \
            "${kernel}" \
            "${conf_linux}" \
            "${conf_initrd}" \
            "${conf_fdtdir}" \
            "${conf_fdt}" \
            "${conf_append}" >> "${conf}"
        # Only create uenv for the first kernel package
        if [[ -z "${has_uenv}" ]]; then
            printf \
                "LINUX=/%s\nINITRD=/%s\nFDTDIR=/%s\n#FDT=/%s\nAPPEND=%s\n"\
                "${conf_linux}"\
                "${conf_initrd}"\
                "${conf_fdtdir}"\
                "${conf_fdt}"\
                "${conf_append}" > cache/root/boot/uEnv.txt
            has_uenv='yes'
        fi
    done
    local script name
    for script in booting/*.sh; do
        name=$(basename "$script")
        if [ "${name}" == 'boot.sh' ]; then
            name="${name%.sh}.scr"
        else
            name="${name%.sh}"
        fi
        mkimage -A arm64 -O linux -T script -C none -d "${script}" cache/root/boot/"${name}" > /dev/null
    done
    install -DTm644 cache/{,root/boot/extlinux/}extlinux.conf
}

install_pkgs() {
    # The initramfs provider was installed by install_initramfs() first, so
    # the alpm hook builds the images automatically as each kernel lands.
    pacman_chroot -Sy --needed --noconfirm "${install_pkgs_kernel[@]}" "${install_pkgs_normal[@]}"
}

install_kernel_pkgs() {
    # Download (or copy) user-supplied .pkg.tar.zst kernel packages, install
    # them with chroot pacman -U, and register their pkgbase into
    # install_pkgs_kernel so setup_initramfs()/setup_extlinux() build the
    # initramfs and boot entries.
    [[ ${#install_pkgs_kernel_pkg[@]} -eq 0 ]] && return
    local src file name pkgbase seen duplicated
    mkdir -p cache/root/var/cache/pacman/pkg
    for src in "${install_pkgs_kernel_pkg[@]}"; do
        if [[ "${src}" =~ ^[a-zA-Z][a-zA-Z0-9+.-]*:// ]]; then
            name="${src##*/}"
            name="${name%%\?*}"
            [[ -n "${name}" ]] || { echo "ERROR: Failed to get file name from '${src}'"; exit 1; }
            file="cache/kernel-pkg/${name}"
            mkdir -p cache/kernel-pkg
            dl "${src}" "${file}"
        else
            file="${src}"
        fi
        [[ -f "${file}" ]] || { echo "ERROR: Kernel package '${file}' not found"; exit 1; }
        [[ "${file}" == *.pkg.tar.zst ]] || echo "Warning: '${file}' does not look like a .pkg.tar.zst"

        # The package file must be visible inside the chroot for pacman -U
        name=$(basename "${file}")
        cp -f "${file}" cache/root/var/cache/pacman/pkg/"${name}"
        # Local packages have no detached signature, use the Never config
        pacman_chroot -U --config /etc/pacman-local.conf --noconfirm "/var/cache/pacman/pkg/${name}"

        # setup_initramfs() builds images per kernel name, fall back to
        # pkgname when the package is not a split package (no pkgbase).
        pkgbase=$(bsdtar -xOf "${file}" .PKGINFO 2>/dev/null | sed -n 's/^pkgbase = //p')
        [[ -n "${pkgbase}" ]] || pkgbase=$(bsdtar -xOf "${file}" .PKGINFO 2>/dev/null | sed -n 's/^pkgname = //p')
        if [[ -n "${pkgbase}" ]]; then
            duplicated=''
            for seen in "${install_pkgs_kernel[@]}"; do
                [[ "${seen}" == "${pkgbase}" ]] && duplicated='yes' && break
            done
            [[ -n "${duplicated}" ]] || install_pkgs_kernel+=("${pkgbase}")
            echo "=> Installed and registered kernel '${pkgbase}' from '${file}'"
        else
            echo "Warning: failed to read .PKGINFO from '${file}', boot config may need manual setup"
        fi
    done
}

install_local_pkgs() {
    # Download (or copy) arbitrary user-supplied .pkg.tar.zst packages and
    # install them with chroot pacman -U. Unlike install_kernel_pkgs() these
    # are not registered as kernels, so no initramfs / boot entry is generated
    # for them. All packages are passed to a single -U call so dependencies
    # between the supplied packages can be resolved together.
    [[ ${#install_pkgs_local[@]} -eq 0 ]] && return
    local src file name
    local files=()
    mkdir -p cache/local-pkg cache/root/var/cache/pacman/pkg
    for src in "${install_pkgs_local[@]}"; do
        if [[ "${src}" =~ ^[a-zA-Z][a-zA-Z0-9+.-]*:// ]]; then
            name="${src##*/}"
            name="${name%%\?*}"
            [[ -n "${name}" ]] || { echo "ERROR: Failed to get file name from '${src}'"; exit 1; }
            file="cache/local-pkg/${name}"
            dl "${src}" "${file}"
        else
            file="${src}"
        fi
        [[ -f "${file}" ]] || { echo "ERROR: Package '${file}' not found"; exit 1; }
        [[ "${file}" == *.pkg.tar.zst ]] || echo "Warning: '${file}' does not look like a .pkg.tar.zst"
        echo "=> Adding package '${file}'"
        name=$(basename "${file}")
        cp -f "${file}" cache/root/var/cache/pacman/pkg/"${name}"
        files+=("/var/cache/pacman/pkg/${name}")
    done
    pacman_chroot -U --config /etc/pacman-local.conf --noconfirm "${files[@]}"
}

cleanup_pkgs() {
    pacman_chroot -Sc --noconfirm
}

setup_root() {
    disable_network
    # /etc/fstab
    echo "# root partition with ext4 on SDcard / USB drive
UUID=${uuid_root}	/	ext4	rw,noatime	0 1
# boot partition with vfat on SDcard / USB drive
UUID=${uuid_boot_specifier}	/boot	vfat	rw,noatime	0 2" >>  cache/root/etc/fstab
    # Timezone
    ln -sf "/usr/share/zoneinfo/UTC" cache/root/etc/localtime
    # Locale
    sed -i 's/^#\(en_US.UTF-8 UTF-8  \)$/\1/g' cache/root/etc/locale.gen
    echo 'LANG=en_US.UTF-8' > cache/root/etc/locale.conf

    # Network
    echo alarm > cache/root/etc/hostname
    printf '127.0.0.1\tlocalhost\n::1\t\tlocalhost\n' >> cache/root/etc/hosts
    printf '[Match]\nName=eth* en*\n\n[Network]\nDHCP=yes\nDNSSEC=no\n' > cache/root/etc/systemd/network/20-wired.network

    # Users
    local sudoers=cache/root/etc/sudoers
    chmod o+w "${sudoers}"
    sed -i 's|^# %wheel ALL=(ALL:ALL) ALL$|%wheel ALL=(ALL:ALL) ALL|g' "${sudoers}"
    chmod o-w "${sudoers}"

    # Actual resolv
    ln -sf /run/systemd/resolve/resolv.conf cache/root/etc/resolv.conf

    # Things that need to bone inside the root
    chroot cache/root /bin/bash -ec "locale-gen
systemctl enable systemd-{network,resolve,timesync}d sshd
useradd --groups wheel --create-home --password '"'$y$j9T$raNZsZE8wMTuGo2FHnYBK/$0Z0OEtF62U.wONdo.nyd/GodMLEh62kTdZXeb10.yT7'"' alarm"
}

archive_root() {
    local archive=out/"${build_id}"-root.tar
    (
        cd cache/root
        bsdtar --acls --xattrs -cpf - *
    ) > "${archive}".temp
    mv "${archive}"{.temp,}
}

image_disk() {
    local image=out/"${build_id}"-base.img
    local temp_image="${image}".temp
    rm -f "${temp_image}"
    truncate -s 2G "${temp_image}"
    echo 'label: dos
        start=8192, size=524288, type=ef
        start=532480, size=3661824, type=83' |
            sfdisk "${temp_image}"
    dd if=cache/boot.img of="${temp_image}" bs=1M seek=4 conv=notrunc
    dd if=cache/root.img of="${temp_image}" bs=1M seek=260 conv=notrunc
    sync
    mv "${temp_image}" "${image}"
}

release() {
    pids_gzip=()
    rm -rf out/latest
    mkdir out/latest
    for suffix in root.tar base.img; do
        gzip -9 out/"${build_id}-${suffix}" &
        pids_gzip+=($!)
        ln -s ../"${build_id}-${suffix}".gz out/latest/
    done
    echo "Waiting for gzip processes to end..."
    wait ${pids_gzip[@]}
}

prepare_host() {
    prepare_host_dirs
    config_repos
    prepare_pacman_static
    prepare_pacman_configs
}

image_boot() {
    local image=cache/boot.img
    rm -f "${image}"
    truncate -s 256M "${image}"
    mkfs.vfat -n 'ALARMBOOT' -F 32 -i "${uuid_boot_mkfs}" "${image}"
    mcopy -osi "${image}" cache/root/boot/* ::
}

cleanup_boot() {
    rm -rf cache/root/boot/*
}

image_root() {
    local image=cache/root.img
    rm -f "${image}"
    truncate -s 1788M "${image}"
    mkfs.ext4 -L 'ALARMROOT' -m 0 -U "${uuid_root}" -d cache/root "${image}"
}

cleanup_cache() {
    # The success path clears the EXIT trap, so cleanup_build() never runs.
    # Unmount cache/root here too, otherwise `rm -rf cache` hits
    # "Device or resource busy" on the still-mounted tmpfs root.
    unmount_root_all || true
    rm -rf cache
}

work_build() {
    check_identity_root
    if [[ "$(uname -m)" != 'aarch64' ]]; then
        # On x86_64 the aarch64 binaries inside the chroot run through qemu
        if [[ -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ]]; then
            echo "INFO: qemu-aarch64 binfmt registered, aarch64 chroot will work" >&2
        else
            echo "WARNING: host is $(uname -m) but qemu-aarch64 binfmt_misc is NOT registered." >&2
            echo "         Install it with: apt install qemu-user-static && sudo systemctl restart systemd-binfmt" >&2
            echo "         Otherwise every chroot command will fail with 'Exec format error'." >&2
        fi
    fi
    trap "cleanup_build" INT TERM EXIT
    prepare_host
    local stage
    for stage in mount_root bootstrap_root prepare_chroot_pacman install_initramfs \
                 install_pkgs install_kernel_pkgs install_local_pkgs setup_initramfs \
                 setup_root setup_extlinux cleanup_pkgs umount_root_sub \
                 archive_root image_boot cleanup_boot image_root; do
        echo "=== [$(date -u +%H:%M:%S)] STAGE: ${stage} ===" >&2
        "${stage}"
    done
    echo "=== [$(date -u +%H:%M:%S)] ALL STAGES DONE ===" >&2
    # The child should have the following artifacts: cache/root.img cache/boot.img cache/extlinux.conf
    # And the stages should have already finished out/*-root.tar
    image_disk
    release
    trap - INT TERM EXIT
    cleanup_cache
}

# Common main routine
install_pkgs_bootstrap=()
install_pkgs_normal=()
install_pkgs_kernel=()
install_pkgs_kernel_pkg=()
install_pkgs_local=()
build_id=''
uuid_root=''
uuid_boot=''
uuid_boot_mkfs=''
uuid_boot_specifier=''

argv=("$@")
argc=$#

i=0
while [[ $i -lt ${argc} ]]; do
    case "${argv[$i]}" in
        --install)
            i=$(( $i + 1 ))
            install_pkgs_normal+=("${argv[$i]}")
            ;;
        --install-bootstrap)
            i=$(( $i + 1 ))
            install_pkgs_bootstrap+=("${argv[$i]}")
            ;;
        --install-kernel)
            i=$(( $i + 1 ))
            install_pkgs_kernel+=("${argv[$i]}")
            ;;
        --install-kernel-pkg)
            i=$(( $i + 1 ))
            install_pkgs_kernel_pkg+=("${argv[$i]}")
            ;;
        --install-local-pkg)
            i=$(( $i + 1 ))
            install_pkgs_local+=("${argv[$i]}")
            ;;
        --uuid-root)
            i=$(( $i + 1 ))
            uuid_root="${argv[$i]}"
            ;;
        --uuid-boot)
            i=$(( $i + 1 ))
            uuid_boot="${argv[$i]}"
            ;;
        --build-id)
            i=$(( $i + 1 ))
            build_id="${argv[$i]}"
            ;;
        --local-mirror)
            pkg_from_local_mirror='yes'
            ;;
        --help)
            help
            exit 0
            ;;
        *)
            echo "ERROR: Unknown arg '${argv[$i]}'"
            help
            exit 1
            ;;
    esac
    i=$(( $i + 1 ))
done

if [[ -z "${build_id}" ]]; then
    build_id=ArchLinuxARM-aarch64-Amlogic-s9xxx-$(date +%Y%m%d_%H%M%S)
fi

if [[ "${#install_pkgs_bootstrap[@]}" == 0 ]]; then
    install_pkgs_bootstrap=(base archlinuxarm-keyring 7ji-keyring)
fi

if [[ "${#install_pkgs_normal[@]}" == 0 ]]; then
    # linux-aarch64-flippy-git-dtb-amlogic and ampart were dropped from the
    # 7Ji repo; use ampart-git which is still published there.
    install_pkgs_normal=(vim nano sudo openssh ampart-git yaopenvfd)
fi

if [[ "${#install_pkgs_kernel[@]}" == 0 && "${#install_pkgs_kernel_pkg[@]}" == 0 ]]; then
    # flippy-git was dropped from the 7Ji repo, so only 7ji remains as the
    # default repo kernel. If the user supplied local kernel packages, don't
    # add a default one: their packages become the kernel set.
    install_pkgs_kernel=(linux-aarch64-7ji)
fi

if [[ -z "${uuid_root}" ]]; then
    uuid_root=$(uuidgen)
fi

if [[ -z "${uuid_boot}" ]]; then
    uuid_boot=$(uuidgen)
fi
uuid_boot_mkfs=${uuid_boot::8}
uuid_boot_mkfs=${uuid_boot_mkfs^^}
uuid_boot_specifier="${uuid_boot_mkfs::4}-${uuid_boot_mkfs:4}"
initramfs="${initramfs:-booster}"

work_build
