cask "orttaai" do
  version "1.0.7"
  sha256 "769f0d4261907f9eedda08a8d11eb2b0b1aee5e102f91b19175eb498ac150d47"

  url "https://github.com/theoyinbooke/orttaai/releases/download/v#{version}/Orttaai-#{version}.dmg"
  name "Orttaai"
  desc "Native macOS voice keyboard using WhisperKit"
  homepage "https://github.com/theoyinbooke/orttaai"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :sonoma"
  depends_on arch: :arm64

  app "Orttaai.app"

  postflight do
    marker = "#{appdir}/Orttaai.app/Contents/Resources/.homebrew-installed"
    File.write(marker, "installed via homebrew\n")
  end

  zap trash: [
    "~/Library/Application Support/Orttaai",
    "~/Library/Preferences/com.orttaai.app.plist",
  ]
end
