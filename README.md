# nb-wrangler-images

## Purpose

This repository maintains copies of the nb-wrangler specs and auxilliary files
used to generate notebook images for STScI's science platforms.

[nb-wrangler](https://github.com/spacetelescope/nb-wrangler.git) is a Python tool used to specify, construct, test, and host notebook images and optionally install related data.  nb-wrangler has a supporting PyPi project.

nb-wrangler-images are hosted by GHCR here: [images](https://github.com/spacetelescope/nb-wrangler/pkgs/container/nb-wrangler-images). Images come in two kinds:  typically large to huge notebook binary images, and very lightweight images containing only the spec used to build the corresponding binary image (that also contains a copy of the spec.)
