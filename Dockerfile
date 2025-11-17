FROM archlinux:latest
LABEL contributor="honjow311@gmail.com"

COPY rootfs/etc/pacman.conf /etc/pacman.conf

COPY manifest /manifest
RUN source /manifest && \
    echo "Server=https://archive.archlinux.org/repos/${ARCHIVE_DATE}/\$repo/os/\$arch" > \
    /etc/pacman.d/mirrorlist

# 初始化 pacman
RUN echo -e "keyserver-options auto-key-retrieve" >> /etc/pacman.d/gnupg/gpg.conf && \
    sed -i '/CheckSpace/s/^/#/g' /etc/pacman.conf && \
    pacman-key --init && \
    pacman --noconfirm -Syyuu

# 安装构建必需工具
RUN pacman --noconfirm -S \
    arch-install-scripts \
    btrfs-progs \
    sudo \
    wget

# Auto add PGP keys for users
RUN mkdir -p /etc/gnupg/ && echo -e "keyserver-options auto-key-retrieve" >> /etc/gnupg/gpg.conf

RUN sed -i '/BUILDENV/s/check/!check/g' /etc/makepkg.conf && \
  sed -i '/OPTIONS/s/debug/!debug/g' /etc/makepkg.conf

USER build
ENV BUILD_USER "build"
ENV GNUPGHOME  "/etc/pacman.d/gnupg"
# Built image will be moved here. This should be a host mount to get the output.
ENV OUTPUT_DIR /output

WORKDIR /workdir
