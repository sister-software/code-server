# Builds a populated Alpine ARM64 rootfs for the iSH (ish-arm64) guest.
# Built for linux/arm64 (native on Apple Silicon), exported, then converted to
# the iSH fakefs format by fakefsify in build-ish.sh.
#
# Bakes in the out-of-box packages + an `operator` user (passwordless sudo, zsh
# login shell, /home/operator). Heavier dev tooling is left to bootstrap.sh,
# which the user runs from inside the guest on first boot.
FROM alpine:3.20

# Out-of-box packages.
#   coreutils  — GNU mkdir/cp/etc.; busybox `mkdir -p` walks from / and trips an
#                iSH fakefs quirk ("can't create directory '/'"), GNU doesn't.
#   gcompat + libstdc++ — glibc shim + C++ runtime so prebuilt-glibc binaries
#                (e.g. nodejs.org's node) can run on this musl userland.
RUN apk add --no-cache \
      sudo \
      openssh \
      git \
      tig \
      curl \
      vim \
      zsh \
      coreutils \
      gcompat \
      libstdc++

# operator: zsh login shell, home /home/operator, no password (root su's in, and
# sudo is passwordless below — no login password is ever needed).
RUN adduser -D -s /bin/zsh -h /home/operator operator \
 && echo 'operator ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/operator \
 && chmod 0440 /etc/sudoers.d/operator \
 && echo 'operator:100000:65536' > /etc/subuid \
 && echo 'operator:100000:65536' > /etc/subgid

# operator's shell config (PATH + reasonable zsh defaults).
COPY operator.zshrc /home/operator/.zshrc
RUN chown operator:operator /home/operator/.zshrc

# Pre-build + byte-compile the zsh completion dump AND the completion function
# digests here (fast on a real arm64 host). The guest then loads compiled .zwc
# files instead of re-parsing hundreds of completion scripts under the
# interpreter — which is what made the first boot and first <Tab> slow.
RUN HOME=/home/operator zsh -fc 'autoload -Uz compinit && compinit -u -d /home/operator/.zcompdump && zcompile -U /home/operator/.zcompdump && for d in $fpath; do f=($d/*(N.)); (( $#f )) && zcompile -U "$d.zwc" $f; done' \
 && chown operator:operator /home/operator/.zcompdump /home/operator/.zcompdump.zwc

# podman storage: iSH has no overlayfs and the fakefs lacks d_type, so the
# default `overlay` driver can't work. Default to `vfs` (plain per-layer copies),
# which works on any filesystem. Pre-seeded so podman uses it out of the box
# (apk preserves this as a local config if podman is later installed).
RUN mkdir -p /etc/containers \
 && printf '[storage]\ndriver = "vfs"\n' > /etc/containers/storage.conf

# First-boot setup script the user runs from the terminal.
COPY bootstrap.sh /usr/local/bin/bootstrap.sh
RUN chmod 0755 /usr/local/bin/bootstrap.sh
