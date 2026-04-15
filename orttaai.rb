cask "orttaai" do
  version "1.1.1"
  sha256 "64dc5979c9950807a03a4feb7a6d67fa0c8fb33775731946bc8f8f5c8b828547"

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
