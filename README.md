# Homelab Base Docker Image

[![Build](https://github.com/tuxgalhomelab/docker-image-base/actions/workflows/build.yml/badge.svg)](https://github.com/tuxgalhomelab/docker-image-base/actions/workflows/build.yml) [![Lint](https://github.com/tuxgalhomelab/docker-image-base/actions/workflows/lint.yml/badge.svg)](https://github.com/tuxgalhomelab/docker-image-base/actions/workflows/lint.yml)

The base docker image used for the docker containers running in tuxgal's
Homelab setup.

The image is based on the `debian:12.2-slim` docker image with some
non-essential contents removed, a few extra packages installed and
also some custom utility scripts that can be used from the child
images.
