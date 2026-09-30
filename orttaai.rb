cask "orttaai" do
  version "1.10.0"
  sha256 "6ed21461a4067754796d74b15d3afe2f56a981d86f59793038461d6c1326c334"

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
