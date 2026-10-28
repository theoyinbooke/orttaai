cask "orttaai" do
  version "1.17.0"
  sha256 "7004dd2bf512040a083597df77f89548a487bab756151f7575903df176498cb3"

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
