#!/bin/bash
# Run manually only after reviewing GITHUB_UPLOAD.md. This publishes to GitHub.
set -euo pipefail
release_dir=/Users/lee2/Documents/Hermeneus/dist/v1.0.0
repo=hubg9527777-dotcom/Hermeneus
cd "$release_dir"
shasum -a 256 -c SHA256SUMS
command -v gh >/dev/null
if ! gh auth status --hostname github.com >/dev/null 2>&1; then
  gh auth login --hostname github.com --git-protocol https --web
fi
gh auth setup-git --hostname github.com
gh api "repos/$repo" --jq '{full_name,visibility,permissions}'
# Empty repository only: stop safely if it already has commits, branches or tags.
remote_refs=$(git ls-remote "https://github.com/$repo.git")
if [ -n "$remote_refs" ]; then
  echo '目标仓库已有内容，已停止；请核对历史，不要强制推送。' >&2
  exit 1
fi
cd source/Hermeneus
if [ -e .git ]; then
  echo '导出目录已有 Git 历史，已停止；请核对上一次发布进度。' >&2
  exit 1
fi
python3 scripts/check_release_security.py
git init -b main
# Derive the authenticated user's recognized GitHub noreply identity.
github_login=$(gh api user --jq .login)
github_id=$(gh api user --jq .id)
git config user.name "$github_login"
git config user.email "$github_id+$github_login@users.noreply.github.com"
git add .
git diff --cached --check
git diff --cached --stat
# One-command signing options do not change global signing settings.
git -c commit.gpgsign=false commit -m "Hermeneus v1.0.0"
git remote add origin "https://github.com/$repo.git"
git -c tag.gpgsign=false tag -a v1.0.0 -m "Hermeneus v1.0.0"
git push --atomic origin main refs/tags/v1.0.0
git branch --set-upstream-to=origin/main main
gh release create v1.0.0 \
  "$release_dir/Hermeneus-v1.0.0-Full.dmg" \
  "$release_dir/Hermeneus-v1.0.0-Source.zip" \
  "$release_dir/SHA256SUMS" \
  "$release_dir/SECURITY_AUDIT_V1.0.0.md" \
  "$release_dir/NATIVE_SECURITY_REVIEW.md" \
  --repo "$repo" --verify-tag --latest \
  --title "Hermeneus v1.0.0" --notes-file "$release_dir/RELEASE_NOTES.md"
gh release view v1.0.0 --repo "$repo" --json url,isDraft,isPrerelease,tagName,assets
