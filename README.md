### Pre-requisites ###

This documentation supports Ubuntu 20.04 LTS version.
However command listed below should work with any recent debian-like Linux
distribution.

## git ##

From https://git-scm.com/:
Git is a free and open source distributed version control system designed to
 handle everything from small to very large projects with speed and efficiency.

To install git:

```bash
  $ sudo apt install git
```

For more informations: https://git-scm.com/

## repo ##

From https://gerrit.googlesource.com/git-repo/:
Repo is a tool built on top of Git. Repo helps manage many Git repositories,
does the uploads to revision control systems, and automates parts of the
development workflow. Repo is not meant to replace Git, only to make it easier
to work with Git. The repo command is an executable Python script that you can
put anywhere in your path.

To install repo:

```bash
  $ mkdir ~/.bin
  $ echo "PATH=~/.bin:\$PATH" >> ~/.bashrc && source ~/.bashrc
  $ curl https://storage.googleapis.com/git-repo-downloads/repo > ~/.bin/repo
```

For more informations: https://gerrit.googlesource.com/git-repo/+/refs/heads/master/README.md

## Docker  ##

From https://docs.docker.com/get-started/overview/:
Docker is an open platform for developing, shipping, and running applications.

To install docker:

```bash
  $ sudo apt install docker.io
```

For more informations: https://www.docker.com/

## cqfd ##

From https://github.com/savoirfairelinux/cqfd:
cqfd provides a quick and convenient way to run commands in the current
directory, but within a Docker container defined in a per-project config file.

To install cqfd:

```bash
  $ git clone git@github.com:savoirfairelinux/cqfd.git
  $ cd cqfd/
  $ sudo make install
```

For more information: https://github.com/savoirfairelinux/cqfd

### Retrieve the project ###

#### Full project ####

To get the COGIP full source tree :

```bash
  $ mkdir cogip/ -p && cd cogip/
  $ repo init -u git@github.com:cogip/cogip-manifest.git -m cogip-manifest.xml
  $ repo sync
  $ cd cogip/pi
```

#### Pi project ####

To get the COGIP pi project source tree only:

```bash
  $ mkdir cogip/ -p && cd cogip/
  $ repo init -u git@github.com:cogip/cogip-manifest.git -m cogip-pi.xml
  $ repo sync
  $ cd cogip/pi
```

### Build cqfd docker image ###

This has to be done only once unless the Dockerfile is modified:

```bash
  $ cqfd init
```

### Build project ###

To build COGIP Pi project for COGIP Raspberry Pi Zero WiFi:

```bash
  $ cqfd
```

### Advanced build setup ###

#### Launch commands through cqfd container ####

Commands can be ran inside cqfd containers as for classical Docker containers.

'cqfd run \<command\>':

```bash
  $ cqfd run bash
  $ cqfd run ls
  $ cqfd run whoami
```

#### Launch Yocto commands through cqfd container ####

Yocto commands are wrapped by 'build.py':

```bash
  $ cqfd run ./build.py bitbake -e cortex-genimage
  $ cqfd run ./build.py bitbake virtual/kernel
  $ cqfd run ./build.py bash
```

#### Advanced build confiuration ####

By default build wrapper 'build.py' is building 'core-image-minimal' Yocto
image.
To override image built, export or set in command line the IMAGE variable:

```bash
  $ cqfd run IMAGE=cortex-genimage ./build.py
```

MACHINE and DISTRO are respectively set by default to 'x86_64' and 'poky' by
bitbake and can be overriden too:

```bash
  $ cqfd run MACHINE=cogip-pi0-w DISTRO=cogip IMAGE=cortex-genimage ./build.py
```
