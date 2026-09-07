# Release template. Keep commented until the GitHub owner, version, checksum,
# and license are selected and the exact source archive has passed verification.
# No repository, tag, or release has been published by this implementation task.
#
# class Cafectl < Formula
#   desc "Control macOS sleep prevention from a menu bar item and CLI"
#   homepage "https://github.com/YOUR_USER/cafectl"
#   url "https://github.com/YOUR_USER/cafectl/archive/refs/tags/vVERSION.tar.gz"
#   sha256 "ARCHIVE_SHA256"
#   # Add the chosen SPDX license after adding its LICENSE file to the source.
#
#   depends_on xcode: ["16.0", :build]
#   depends_on macos: :ventura
#
#   def install
#     system "swift", "build", "--configuration", "release", "--disable-sandbox"
#     bin.install ".build/release/cafectl"
#   end
#
#   service do
#     run [opt_bin/"cafectl", "start"]
#     run_at_load true
#     keep_alive false
#     process_type :interactive
#     log_path var/"log/cafectl.log"
#     error_log_path var/"log/cafectl.error.log"
#   end
#
#   test do
#     assert_match "cafectl", shell_output("#{bin}/cafectl --help")
#   end
# end
