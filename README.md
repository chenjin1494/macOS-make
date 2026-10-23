# macOS-make

用 GitHub Actions 在 macOS 运行器上，按官方 `createinstallmedia` 流程制作 macOS 安装镜像（`.iso`），
自动发布到 GitHub Release 提供下载链接。

流程完全对应博客 [《制作 macOS Catalina 正式版安装镜像 .cdr 或 .iso 文件》](https://blog.csdn.net/qq_40627654/article/details/105378155)
的「官方制作镜像」部分：

| 博客命令 | 工作流中的步骤 |
| --- | --- |
| `hdiutil create -o /tmp/Catalina -size 8500m -volname Catalina -layout SPUD -fs HFS+J` | 1. 创建一个 dmg |
| `hdiutil attach /tmp/Catalina.dmg -noverify -mountpoint /Volumes/Catalina` | 2. 挂载 |
| `sudo .../createinstallmedia --volume /Volumes/Catalina --nointeraction` | 3. 写入安装器 |
| `hdiutil detach /volumes/Install macOS Catalina` | 4. 卸载 |
| `hdiutil convert /tmp/Catalina.dmg -format UDTO -o ~/Desktop/Catalina.cdr` | 5. 转换为 cdr |
| `mv ~/Desktop/Catalina.cdr ~/Desktop/Catalina.iso` | 6. 改名成 iso |

唯一区别：CI 无法登录 App Store 下载安装器，所以安装器改用 Apple 官方命令行渠道获取
（`scripts/download-installer.sh`）：

1. `sudo softwareupdate --fetch-full-installer --full-installer-version <版本>`（优先）
2. 10.13–10.15 若运行器不提供该版本，则从 `swcdn.apple.com` 直链拼装
   （BaseSystem.dmg + InstallESDDmg.pkg + InstallInfo.plist，参考
   [mkmaciso](https://github.com/LongQT-sea/mkmaciso) 的做法）
3. 仅在宿主 macOS < 15.6 时才尝试 [MIST](https://github.com/ninxsoft/mist-cli)

> 注意：macOS 15.6 起 Apple 修复 CVE-2025-43187，`installer -pkg` 不再能安装旧安装器
> （报 `Opened package is not the same at install time`），依赖它的 MIST 在 15.6+ 及
> 其后的运行器上都会失败（[Mist#215](https://github.com/ninxsoft/mist-cli/issues/215)、
> [Mist#198](https://github.com/ninxsoft/mist-cli/issues/198)）。因此这里绕开 `installer`。
> 另外 Apple Silicon 上 Catalina 的 `createinstallmedia` 不可用，10.x 请用 Intel 运行器。

## 使用方法

1. 打开仓库的 **Actions → Build macOS install ISO → Run workflow**
2. 填写参数（默认即按博客制作 Catalina 10.15.7）：
   - `version`：macOS 版本，如 `10.15.7`、`11.7.10`、`13.7.6`
   - `name`：镜像文件名，如 `Catalina`
   - `dmg_size`：`hdiutil -size` 参数，Catalina 用 `9000m`
   - `runner`：运行器，10.15 及更早必须用 Intel 运行器（默认 `macos-15-intel`）
3. 完成后到 **Releases** 下载，固定地址：

   https://github.com/chenjin1494/macOS-make/releases/tag/macos-Catalina-10.15.7

## 下载后怎么用

GitHub 单个发布文件上限 2 GiB，镜像被切成约 1.9 GiB 的分卷，先拼接再校验：

```bash
# macOS / Linux
cat Catalina.iso.part-* > Catalina.iso
shasum -a 256 -c SHA256SUMS.txt
```

```bat
:: Windows
copy /b Catalina.iso.part-* Catalina.iso
```

`SHA256SUMS.txt` 第一行是拼接后整镜像 `Catalina.iso` 的哈希，其余为各分卷的哈希，
所以拼接完直接 `shasum -a 256 -c SHA256SUMS.txt` 就能同时校验整镜像和分卷。
每次重新构建的镜像带不同的卷内时间戳，哈希会变，请以最新 Release 里的 `SHA256SUMS.txt` 为准。

在 VMware 中安装：`.vmx` 文件里加入 `smc.version = "0"`（Catalina 实际约是 10.15.1，建议 VMware 15.5.1）。

## 说明

- 镜像约 8.4 GB，制作过程需要约 25 GiB 可用磁盘（macOS 运行器的数据卷通常有 100 GiB 以上）
- 若运行器里 `softwareupdate --list-full-installers` 没有目标版本，脚本会自动走 swcdn 直链拼装
- `macos-15-intel` / `macos-26-intel` 是 Intel 运行器，跑 `createinstallmedia` 兼容性最好；10.13–10.15 在 Apple Silicon 上会直接报错退出
- 镜像版权归 Apple，仅供个人测试、学习使用
