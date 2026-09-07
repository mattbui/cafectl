class Cafectl < Formula
  desc "Control macOS sleep prevention from a menu bar item and CLI"
  homepage "https://github.com/mattbui/cafectl"

  # BEGIN RELEASE
  # The release workflow adds versioned binary URLs and checksums here.
  # END RELEASE

  head "https://github.com/mattbui/cafectl.git", branch: "main"

  depends_on :macos
  on_macos do
    depends_on macos: :ventura
  end

  head do
    depends_on xcode: ["16.0", :build]
  end

  def install
    if build.head?
      system "swift", "build", "--configuration", "release", "--disable-sandbox"
      bin.install ".build/release/cafectl"
    else
      bin.install "cafectl"
    end
    pkgshare.install "THIRD_PARTY_NOTICES.md", "LICENSES.md"
  end

  service do
    run [opt_bin/"cafectl", "start"]
    run_at_load true
    keep_alive false
    process_type :interactive
    log_path var/"log/cafectl.log"
    error_log_path var/"log/cafectl.error.log"
  end

  test do
    assert_match "Usage: cafectl", shell_output("#{bin}/cafectl --help")
  end
end
