# Hermeneus v1.0.0 正式 GitHub 发布命令（未执行）

目标沿用此前交付文档指定的新仓库 `hubg9527777-dotcom/Hermeneus`。原工作目录旧 remote 为 `secure-artifacts/Hermeneus`，本命令不会使用或修改它。执行前核对目标账户及仓库权限；目标必须已创建且为空，脚本遇到已有分支/标签会停止，不强制推送。若目标需要更改，先修改脚本内 repo。

本地最终验收结果见 SECURITY_AUDIT_V1.0.0.md。当前允许按已接受的未公证分发限制创建正式 Release；不是草稿。没有执行以下步骤。

需要已安装 Git、Python 3 和 GitHub CLI。脚本先校验交付文件，再使用浏览器完成 HTTPS 登录（已登录则复用），自动采用当前 GitHub 用户的 noreply 提交邮箱，仅在干净源码导出目录创建新历史，最后原子推送 main/v1.0.0 并创建正式 Release。

## 完整命令

```bash
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
```

等价执行：

```bash
bash /Users/lee2/Documents/Hermeneus/publish-v1.0.0.sh
```

若推送成功但附件上传中断，不要强推或删除标签；先用 `gh release view v1.0.0 --repo hubg9527777-dotcom/Hermeneus` 核对状态，再针对缺失步骤恢复。

## 关于硬件密钥

本地构建、临时代码签名和验收不需要 GitHub 安全密钥。脚本不使用 SSH/FIDO 硬件签名，也不会更改全局签名设置。GitHub 网页登录若要求二次验证，使用账户已配置的其他验证方式（验证器、通行密钥或恢复码）；无法由此脚本跳过账户认证，也不要关闭双重验证。说明见 [GitHub 官方二次验证文档](https://docs.github.com/en/authentication/securing-your-account-with-two-factor-authentication-2fa/accessing-github-using-two-factor-authentication)。正式 Release 参数见 [GitHub CLI 文档](https://cli.github.com/manual/gh_release_create)。
