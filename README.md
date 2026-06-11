# VPS Init

中文交互式 VPS 新机初始化脚本，面向新手和低配/NAT VPS 场景。

当前重点适配：

- Debian / Ubuntu
- CentOS / RHEL / Rocky / Alma
- Alpine 3.21 / 3.22 / 3.23（OpenRC / apk）

## 快速使用

在测试 VPS 上执行：

```bash
curl -fsSL https://raw.githubusercontent.com/lzkyou/vps.init.sh/main/vps-init.sh -o vps-init.sh
bash -n vps-init.sh
sudo bash vps-init.sh
```

Alpine 默认可能没有 bash。root 用户可这样启动，脚本会在缺少 bash 时提示安装：

```sh
wget -q -O vps-init.sh https://raw.githubusercontent.com/lzkyou/vps.init.sh/main/vps-init.sh
sh vps-init.sh
```

如果你怀疑 raw 缓存没有刷新，可以强制绕过缓存：

```bash
curl -fsSL "https://raw.githubusercontent.com/lzkyou/vps.init.sh/main/vps-init.sh?$(date +%s)" -o vps-init.sh
grep 'SCRIPT_VERSION=' vps-init.sh
```

建议首次测试顺序：

1. 查看当前配置状态
2. NAT/端口映射设置
3. 极简安全初始化
4. 一键推荐初始化

## 注意

- 高风险 SSH 操作前请不要关闭当前终端。
- NAT VPS 需要确认服务商面板的公网端口映射。
- 128MB RAM 机器建议只跑极简安全初始化。
- SSH Key 配置会检测已有 `authorized_keys`；默认跳过，避免覆盖服务商面板预置 key。
- Alpine 小机通常很轻量，部分包可能需要启用 community 仓库。
- 工具包安装会逐项询问；`git`、`vim`、`htop` 等并非基础必需，按需选择即可。
- 诊断工具包含 `jq`，很多 VPS 测评脚本和云 API 脚本会用它解析 JSON。
- SSH 加固里的 root 登录、密码登录和基础限制已合并为“统一配置 SSH 登录策略”，避免重复预览和重复重启。
- Alpine/OpenRC 上 SSH 加固会写入 `/etc/ssh/sshd_config` 的脚本管理块，并在重启后用 `sshd -T` 校验最终生效值。
- Alpine/OpenRC 的登录策略管理块会放在 `sshd_config` 文件顶部，避免镜像默认值先被读取导致脚本设置不生效。
- 不建议直接在 WSL 内完整执行初始化脚本；WSL 只适合做语法和静态检查。

## 本地验证

```bash
bash -n vps-init.sh
shellcheck vps-init.sh
```
