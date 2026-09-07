#!/usr/bin/env ruby
# Update only release metadata, preserving the formula's service and install logic.
require "digest"

tag, artifact_dir, formula_path = ARGV
abort "Usage: update-formula.rb vX.Y.Z ARTIFACT_DIR FORMULA" unless ARGV.length == 3
abort "Expected a stable vX.Y.Z tag" unless /\Av(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)\z/.match?(tag)
version = tag.delete_prefix("v")
formula = File.read(formula_path)
marker = /^  # BEGIN RELEASE\n.*?^  # END RELEASE$/m
abort "Expected exactly one release metadata block" unless formula.scan(marker).length == 1
metadata = ["  # BEGIN RELEASE", "  version \"#{version}\"", ""]
%w[arm64 x86_64].each do |arch|
  filename = "cafectl-#{tag}-macos-#{arch}.tar.gz"
  checksum = Digest::SHA256.file(File.join(artifact_dir, filename)).hexdigest
  metadata.concat([
    "  on_#{arch == 'arm64' ? 'arm' : 'intel'} do",
    "    url \"https://github.com/mattbui/cafectl/releases/download/#{tag}/#{filename}\"",
    "    sha256 \"#{checksum}\"",
    "  end",
    ""
  ])
end
metadata << "  # END RELEASE"
File.write(formula_path, formula.sub(marker) { metadata.join("\n") })
