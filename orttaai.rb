cask "orttaai" do
  version "1.2.11"
  sha256 "ab7f5134ab6a2a1f66553c4c190c4ca189f5890cda87b556e53beb3128a25533"

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
