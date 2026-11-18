cask "melon-tools" do
  version "6.0.2"
  sha256 "ce272579c3c18aadf2afee9baf2d73daafea34b590f03f9e6151fb182c49d413"

  url "https://github.com/vanich-git/MelonTools/releases/download/v#{version}/MelonTools-#{version}.dmg"
  name "Melon Tools"
  desc "Codex account pool, local gateway, and scheduled model tasks"
  homepage "https://github.com/vanich-git/MelonTools"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :sonoma"

  app "Melon Tools.app"

  zap trash: [
    "~/Library/Application Support/MelonTools",
    "~/Library/Caches/dev.melontools.app",
    "~/Library/Logs/MelonTools",
    "~/Library/Preferences/dev.melontools.app.plist",
  ]
end
