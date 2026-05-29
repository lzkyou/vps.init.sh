# VPS Init

中文交互式 VPS 新机初始化脚本，面向新手和低配/NAT VPS 场景。

## 快速使用

在测试 VPS 上执行：

```bash
curl -fsSL https://raw.githubusercontent.com/lzkyou/vps.init.sh/main/vps-init.sh -o vps-init.sh
bash -n vps-init.sh
sudo bash vps-init.sh
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
- 不建议直接在 WSL 内完整执行初始化脚本；WSL 只适合做语法和静态检查。

## 本地验证

```bash
bash -n vps-init.sh
shellcheck vps-init.sh
```
