# Package

version       = "0.1.0"
author        = "Emery Hemingway"
description   = "Tox bot for recording and publishing audio and video"
license       = "GPL-3.0-or-later"
srcDir        = "src"
bin           = @["recorder_bot"]



# Dependencies

requires "nim >= 1.2.0", "toxcore >= 0.2.0", "opusenc"

import distros
if detectOs(NixOS):
  foreignDep "openssl"
