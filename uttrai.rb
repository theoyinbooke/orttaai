cask "uttrai" do
  version "1.0.0"
  sha256 "PLACEHOLDER_SHA256"

  url "https://github.com/theoyinbooke/uttrai/releases/download/v#{version}/Uttrai-#{version}.dmg"
  name "Uttrai"
  desc "Native macOS voice keyboard using WhisperKit"
  homepage "https://github.com/theoyinbooke/uttrai"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :sonoma"
  depends_on arch: :arm64

  app "Uttrai.app"

  postflight do
    marker = "#{appdir}/Uttrai.app/Contents/Resources/.homebrew-installed"
    File.write(marker, "installed via homebrew\n")
  end

  zap trash: [
    "~/Library/Application Support/Uttrai",
    "~/Library/Preferences/com.uttrai.app.plist",
  ]
end
