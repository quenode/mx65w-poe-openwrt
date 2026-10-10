The BCM59111 PSE firmware blob
==============================

bcm59111.bin
------------

SPDX-License-Identifier: GPL-2.0-only

This file is the PSE (Power Supply Equipment) firmware image that
bcm59111.c uploads to the Broadcom BCM59111 over I2C before it will
negotiate power with any attached device. Without it the controller
starts but never enables either PoE port.

Provenance
~~~~~~~~~~

Extracted from Cisco Systems' GPL firmware release for the Meraki
MX64/MX65:

    https://dl.meraki.net/wired-14-39-mx64-20190426.tar.bz2

Cisco publishes this release under the GNU General Public License
version 2, the terms of which are in the LICENSE file at the root of this
repository. The blob is redistributed here unmodified, under the same
license, because it is a required part of a GPL-2.0 derivative work and
cannot be substituted without re-deriving it from the same source.

It is a binary, so it cannot carry an in-file comment header. This file
serves as its notice.

Cisco, Meraki and MX65 are trademarks of Cisco Systems, Inc. This file is
not affiliated with or endorsed by Cisco Systems, Inc.