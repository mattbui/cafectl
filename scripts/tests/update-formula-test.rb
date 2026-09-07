require "minitest/autorun"
require "tmpdir"
require "digest"
require "fileutils"
require "open3"

class UpdateFormulaTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)

  def setup
    @dir = Dir.mktmpdir("cafectl-release")
    @formula = File.join(@dir, "cafectl.rb")
    FileUtils.cp(File.join(ROOT, "Formula/cafectl.rb"), @formula)
    %w[arm64 x86_64].each do |arch|
      File.write(File.join(@dir, "cafectl-v0.1.0-macos-#{arch}.tar.gz"), arch)
    end
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def update(tag = "v0.1.0")
    Open3.capture3("ruby", File.join(ROOT, "scripts/update-formula.rb"), tag, @dir, @formula)
  end

  def test_generates_both_architectures_and_preserves_service
    original_service = File.read(@formula).split("  service do", 2).last
    _, error, status = update
    assert status.success?, error
    result = File.read(@formula)
    %w[arm64 x86_64].each do |arch|
      assert_includes result, "cafectl-v0.1.0-macos-#{arch}.tar.gz"
      assert_includes result, Digest::SHA256.hexdigest(arch)
    end
    assert_equal original_service, result.split("  service do", 2).last
    assert update.last.success?
    assert_equal result, File.read(@formula)
  end

  def test_rejects_invalid_tags_without_modifying_formula
    original = File.read(@formula)
    ["v0.1.0-beta", "v01.1.0", "0.1.0", "v1.2.3\nmalicious"].each do |tag|
      refute update(tag).last.success?
      assert_equal original, File.read(@formula)
    end
  end

  def test_missing_archive_does_not_modify_formula
    original = File.read(@formula)
    File.delete(File.join(@dir, "cafectl-v0.1.0-macos-x86_64.tar.gz"))
    refute update.last.success?
    assert_equal original, File.read(@formula)
  end
end
