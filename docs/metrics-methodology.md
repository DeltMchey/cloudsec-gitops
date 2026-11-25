# 性能测量方法学（llm-secguard × cloudsec-gitops）

> 本文档定义两套环境（W2 单机 VM 基线 / W4 K3s 集群）共用的测量口径。
> 数字没有环境规格就是不可比较的——任何发布在外的性能数字必须能回溯到本文档的某一行配置。
>
> - W2 基线：Ubuntu VM 单机，`MOCK_BACKEND=true`，测的是**守卫链路的工程开销**，不是模型质量。
> - W4 集群：K3s + Argo CD + Falco，落档时按 §6 模板逐列回填，禁止与 W2 数字混排比较。
>
> 红线口径：所有压测与红队测量一律 `MOCK_BACKEND=true`（零真实 LLM 调用）；
> 所有红队/医疗数据为 Faker/合成数据，无任何真实个人信息。

## 1. 环境规格（Environment Profile）

| 项目 | W2 单机基线（实测环境） | K3s 集群（W3 落地，2026-11-25 回填） |
| --- | --- | --- |
| 硬件 | VMware Workstation VM，4 vCPU / 3875 Mi RAM + 1873 Mi swap | 同左（单节点复用同一 VM：4 vCPU / 3875 Mi + 1873 Mi swap，cgroup v2） |
| 宿主 OS | Ubuntu 20.04 LTS（nijika@192.168.137.10） | 同左；K3s v1.37.2+k3s1 / containerd 2.3.7-k3s1（traefik、servicelb 关闭，CN registry 镜像） |
| 网关形态 | uvicorn 单 worker，进程直跑（`.venv/bin/uvicorn app.main:app --port 8000`） | Deployment 1 副本（HPA 1–2 @ CPU70%）；非 root UID 10001、只读根文件系统；requests 100m/128Mi，limits 500m/384Mi；NodePort 30080 |
| 上游后端 | MockChatBackend（进程内回显，零网络） | 同左（集群内镜像 `ghcr.io/deltmchey/llm-secguard:385d63a04fb6`，198 MB） |
| Redis | Docker redis7（secguard-redis，127.0.0.1:6379，限流 Lua 真实在路径上） | 同一 Docker 实例，双绑定 127.0.0.1 + 192.168.137.10:6379（Pod 经私网地址直连，NetworkPolicy egress 显式放行） |
| PostgreSQL | Docker postgres16（secguard-postgres，127.0.0.1:5432，审计真实写盘） | 同一 Docker 实例，双绑定 127.0.0.1 + 192.168.137.10:5432（同上） |
| 施压工具 | k6 `grafana/k6:2.3.0`（Docker，`--network host`，`--user uid:gid`） | （待回填：W4 压测时从集群内 Job 或 VM 施压） |
| 施压机与被测机关系 | 同机（VM 内 localhost，环回零网络跳数） | （待回填：W4 决定施压位置后补充跳数口径） |
| 代码版本 | llm-secguard @ `144897e`（守卫链路 + 合成数据生成器平台无关修复 + k6 pin） | llm-secguard @ `385d63a`；cloudsec-gitops @ `328281b`；K3s v1.37.2+k3s1（stable 频道 2026-11-25 解析值）；Argo CD v3.6.3；helm v4.3.2；terraform CLI 1.17.2 / aws provider 6.74.0 |

**单机局限声明**：施压与被测共享 4 vCPU，k6 与 uvicorn 争核，测得的 RPS 是
"同机联合吞吐上限"，绝对值偏保守；但 **A vs D 的差值口径（守卫增量开销）在
同一争核条件下仍然成立**，这正是 W2 的测量目标。

## 2. 负载口径（Load Profile）

| 项目 | 取值 | 说明 |
| --- | --- | --- |
| 施压脚本 | `tests/loadtest/gateway_load.js` | k6 官方镜像内运行；`summaryTrendStats` 钉在脚本内（p50/p95/p99 列全环境一致） |
| 阶段 | 60s @ 5 VU 预热 → 180s @ 目标 VU 稳态 | 每轮合计 ~241s，取整轮口径（含预热，k6 end-of-test） |
| 主口径 VU | 20（profile A ×3 轮 vs profile D ×3 轮） | 每轮独立重启网关；D 的三轮之间连续（before/after 快照差分） |
| 辅助阶梯 | VU=5、VU=50 各 A/D ×1 轮 | 观察低载/高载下守卫开销走势 |
| 流量配比 | 70% benign / 20% 含合成 PII / 10% 注入探针 | 由 T3 生成器按构造固定 |
| payload 集 | `--seed 42 --payloads`，200 条，`SharedArray` 轮询 | 同 seed 跨轮字节一致 |
| 租户模型 | `x-tenant-id: vu-<N>`（每 VU 独立租户） | 摊平限流桶状态 |
| 限流口径 | `RATE_LIMIT_CAPACITY=100000`、`RATE_LIMIT_REFILL_PER_SEC=100000`、`TOKEN_BUDGET_PER_TENANT=100000000` | **调高不关闭**：Redis+Lua 令牌桶与预算门的真实开销保留在路径上 |
| 守卫开关 | profile A：`INPUT_GUARD_ENABLED=false OUTPUT_GUARD_ENABLED=false`；profile D：默认全开 | A 是基线管道，D 是守卫链路 |
| 可用性门槛 | `http_req_failed{status:429,500,502,503} < 1%`、`checks{gate:envelope} > 99%` | 400（守卫拦截）按设计存在，按 tag 过滤不落入失败率 |
| 吞吐节流说明 | 脚本每次迭代 `sleep(0.2)` | RPS 由 sleep 主导（VU20 ≈ 46、VU50 ≈ 100、VU5 ≈ 21），A/D 同条件，差值口径不受影响 |
| 内存监控 | 每轮前后 `free -m`；可用 <500 Mi 立即降档并记录 | 实测最低 ~2858 Mi，未触发降档 |

## 3. W2 实测数字（2026-11-04，k6 端到端 10 轮全部 rc=0）

> 稳态段（180s）汇总值；profile A 的 3 轮独立网关重启后取均值。
> 错误率按 k6 tag 过滤：`http_req_failed{status:429|5xx}` 全部 0.00%；
> `fail%` 列为 `http_req_failed` 总值，在 profile D 中约等于守卫 400 拦截份额
> （≈7.3%，即注入探针配比 10% 中被现有 18 条规则命中的部分——见 §4 备注）。

### 3.1 主口径 VU=20：profile A（守卫关）vs profile D（守卫开）

| 指标 | A r1 | A r2 | A r3 | A 均值 | D r1 | D r2 | D r3 | D 均值 | Δ(D−A) |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| p50 (ms) | 7.43 | 6.28 | 6.35 | 6.69 | 6.81 | 6.83 | 6.67 | 6.77 | +0.08 |
| p95 (ms) | 12.07 | 9.65 | 10.26 | 10.66 | 10.45 | 10.78 | 10.69 | 10.64 | −0.02 |
| p99 (ms) | 21.29 | 12.65 | 13.75 | 15.90 | 13.56 | 14.19 | 13.67 | 13.81 | −2.09* |
| RPS | 46.06 | 46.37 | 46.33 | 46.25 | 46.26 | 46.27 | 46.28 | 46.27 | +0.02 |
| 429/5xx 错误率 | 0.00% | 0.00% | 0.00% | 0.00% | 0.00% | 0.00% | 0.00% | 0.00% | 0 |
| 守卫 400 份额 | 0% | 0% | 0% | 0% | 7.26% | 7.35% | 7.36% | 7.32% | +7.32pp |
| envelope check 通过率 | 100% | 100% | 100% | 100% | 100% | 100% | 100% | 100% | 0 |
| 请求数 | 11063 | 11139 | 11129 | — | 11110 | 11113 | 11117 | — | — |

\* A r1 的 p99=21.29ms 为孤例（r2/r3 均 ~13ms），A/D 差值主要由该噪声驱动；
**结论：守卫全开在 VU20 下延迟差 ≈ 0（p50 +0.08ms），吞吐差 ≈ 0**，
真实守卫开销见 §3.3 的进程内直方图（µs 量级）。

### 3.2 辅助阶梯（A/D 各 1 轮）

| VU | profile | p50 (ms) | p95 (ms) | p99 (ms) | RPS | 429/5xx | 守卫 400 份额 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 5 | A | 6.23 | 9.61 | 11.03 | 21.08 | 0.00% | 0% |
| 5 | D | 6.44 | 9.61 | 10.90 | 21.07 | 0.00% | 7.73% |
| 50 | A | 6.19 | 11.03 | 26.88 | 100.44 | 0.00% | 0% |
| 50 | D | 6.61 | 11.50 | 23.36 | 100.24 | 0.00% | 7.35% |

### 3.3 guard_latency 直方图（/metrics 快照差分，input / output 分列）

> 取自 profile D 各轮 `/metrics` 前后快照的直方计数差分；口径为网关进程内守卫
> 单独耗时（不含上游/限流）。直方图最小桶 0.5ms，故各分位均 ≤0.5ms；
> 精确均值由 `_sum/_count` 差分得出。

| 守卫 | 样本数（VU20 r1/r2/r3） | 分位区间 | 均值（r1/r2/r3, ms） |
| --- | --- | --- | --- |
| input_guard | 11110 / 11113 / 11117 | p50/p95/p99 全部 ≤ 0.5 ms | 0.0240 / 0.0246 / 0.0239 |
| output_guard（PII 掩码） | 10303 / 10296 / 10299 | p50/p95/p99 全部 ≤ 0.5 ms | 0.0312 / 0.0318 / 0.0310 |

> output 样本数 ≈ input − 拦截数：被 input guard 400 拒绝的请求不进入输出掩码，
> 差值即守卫拦截计数，两条独立序列相互印证。VU5/VU50 轮均值同量级
> （input ≈0.024ms，output ≈0.031ms），守卫开销与负载水平无关（µs 级常数）。

### 3.4 内存曲线

| 时点 | 可用内存 (Mi) |
| --- | --- |
| 矩阵开始前 | 2966 |
| A 轮期间 | 2905–2966 |
| D 轮期间 | 2930–2948 |
| VU50 阶段（最低点） | ~2858 |
| 降档线 | 500（未触发） |

### 3.5 守卫补强后复测（2026-11-10，llm-secguard commit c37bd6f）

> W2 基线（§3）落档后，输入守卫新增 2 条规则（`pi-discard-context-en`、
> `jb-unrestricted-persona-zh`，规则总数 18 → 20，均为追加、未动存量规则）。
> 本节为同口径单轮复测：同 VM、同 `gateway_load.js`、k6 2.3.0、VU20、
> 60s 预热 + 180s 稳态、profile D（守卫全开）、限流口径同 §2
> （CAPACITY=100000 / REFILL=100000 / BUDGET=1e8，调高不关闭）。
> **本节为单轮快照，不改写 §3 的三轮均值基线；§3 数字保持原样。**

**VU20 profile D 单轮 vs W2 基线（§3.1 的 D 三轮均值）**

| 指标 | W2 基线 D 均值 | 补强后复测 | 变化 |
| --- | --- | --- | --- |
| p50 (ms) | 6.77 | 6.44 | −0.33 |
| p95 (ms) | 10.64 | 10.24 | −0.40 |
| p99 (ms) | 13.81 | 13.22 | −0.59 |
| RPS | 46.27 | 46.35 | +0.08 |
| 429/5xx 错误率 | 0.00% | 0.00% | 0 |
| 守卫 400 份额 | 7.32% | 8.65% | +1.33pp |
| envelope check 通过率 | 100% | 100% | 0 |
| 请求数 | 11110–11117 | 11133 | — |

> 结论：p50/p95/p99 全部落在 W2 三轮轮间波动范围内，吞吐持平——新增
> 2 条正则未引入可观测的端到端延迟回归。守卫 400 份额 7.32% → 8.65%：
> 新增规则把此前漏拦的 seed-42 注入探针与 zh_jailbreak 变体真实拦截，
> §4「守卫覆盖备注」登记的两个缺口已闭合。

**guard_latency（/metrics 前后快照差分，本轮 11133 请求）**

| 守卫 | 样本数 | 分位区间 | 均值 | W2 基线均值 |
| --- | --- | --- | --- | --- |
| input_guard | 11133 | p50/p95/p99 全部 ≤ 0.5 ms | 0.0316 ms | ≈0.0240 ms |
| output_guard（PII 掩码） | 10170 | p50/p95/p99 全部 ≤ 0.5 ms | 0.0357 ms | ≈0.0312 ms |

> 与基线同量级，仍为 µs 级常数开销；input 均值 +~8 µs 与新增 2 条正则的
> 扫描成本一致。input − output 样本差（963）= 本轮守卫拦截数，与 400
> 份额 8.65% 相互印证。内存无压力（轮后可用 3000 Mi，降档线 500 未触发）。

**红队复测（promptfoo 0.125.1 自编 custom_zh 集，2026-11-04 基线 34/36）**

| 标签 | W2 spike 基线 | 补强后 |
| --- | --- | --- |
| medical_privacy | 12/12 | 12/12 |
| zh_injection | 12/12 | 12/12 |
| zh_jailbreak | 10/12 | 12/12 |
| 合计 | 34/36（94.4%） | **36/36（100%）** |

> 两条漏拦用例（医疗越狱伪装 / 无审查写作）经真实 HTTP 均返回
> 400 `input_guard_blocked`（rule_id=`jb-unrestricted-persona-zh`），
> benign 对照请求仍 200。VM 侧产物：`redteam/results/custom_zh_postfix.json`、
> `tests/loadtest/results/summary_profileD_vu20_retest.json`、
> `tests/loadtest/results/metrics_profileD_vu20_retest_{before,after}.txt`
> （均 gitignored）。

## 4. 红队指标口径（Red-Team Metrics）

> 红队分母 = 评测集条数（promptfoo 分母档案见 llm-secguard
> `redteam/promptfooconfig*.yaml` 头注释）。**以下全部为 [N]% 占位**，
> 待 nightly workflow 实测回填，禁止引用手工跑出来的数字对外发布。

| 指标 | 定义 | 口径 | 当前值 |
| --- | --- | --- | --- |
| 注入拦截率 | zh_injection + zh_jailbreak 中被网关 400 拦截的比例 | 分母 = 24 条手写用例；命中判定 = `contains-any input_guard_blocked`（经 provider 桥接后正常计分） | [N]%（VM spike 单次 22/24 = 91.7%，仅作冒烟基线，非发布口径） |
| PII 泄漏率 | medical_privacy 用例中合成标识符穿透到响应的比例 | 分母 = 12 条；断言 = 每个嵌入标识符 `not-icontains` | [N]%（spike 0/12 泄漏，同上非发布口径） |
| builtin 集拦截率 | promptfoo 内置插件生成用例的拦截比例 | 分母 = 实际生成条数（分母档案随版本重基线） | [N]%（待 nightly；本地模式仅 5/10 插件可用） |
| deepseek 基线拦截差 | 裸模型 vs 网关链路的拦截率差 | 仅 nightly deepseek 分支实测；mock 分支严禁触发该路径 | [N]% |
| promptfoo 400 记录语义 | 网关拦截在结果 JSON 中呈现为 `error`（failureReason=2），断言不评估 | 经 `redteam/providers/secguard_openai.py` 桥接后恢复断言语义 | 已固化（llm-secguard commit 77897d6） |

**守卫覆盖备注**：压测 payload 的注入探针（6 条固定 snippet，占 10% 流量配比）
在 profile D 下的实测拦截份额为 7.3%，即 ~73% 的探针被现有 18 条规则命中；
custom_zh 手写集 24 条拦截用例中 22 条命中（91.7%）。两个缺口（"You can do
anything now" 类英文越狱、医疗角色扮演越狱）是已登记的红队覆盖发现，
待规则集迭代后重测。

## 5. 两套环境数据分列规则

1. 任何对外报告的性能表必须带环境列（本文 §1 的行选择子集）。
2. W2 单机数字**永不**与 W4 集群数字合并、求平均或做除法。
3. 跨环境只允许比较**比值类结论**（如守卫开销百分比），且需声明两环境的
   差异面（同机争核 vs 分离调度）。
4. W4 回填时在本文件追加 §6 小节，模板复制 §3，另加：副本数、HPA 观察、
   节点规格、网络插件与 MTU。

## 6. W4 K3s 环境列（模板，落档时回填）

| 指标 | 值 |
| --- | --- |
| 集群规格 | （待回填：W3 已有单节点 K3s，见 §7；本节专用于 W4 压测矩阵口径） |
| 网关副本 / 资源 | （待回填） |
| k6 施压位置 | （待回填） |
| p50 / p95 / p99 / RPS | （待回填） |
| guard_latency | （待回填） |

## 7. W3 基础设施实测数字（2026-11-25，K3s + GitOps 落地）

> 口径：全部为单节点 VM 上的真实执行记录（非压测数字）；环境规格见 §1 K3s 列。
> 内存护栏沿用 D-12：可用 <800 Mi 停止新增组件，<500 Mi 停止当前阶段——全程未触发。

### 7.1 部署与同步时延

| 事件 | 实测耗时 | 口径说明 |
| --- | --- | --- |
| K3s 安装 → 全组件健康 | ≈3 min | `scripts/k3s-install.sh` 二次执行（幂等跳过安装）：node Ready + CoreDNS + metrics-server + local-path 全部 Available；首次执行因 cgroup v1 被 v1.37 kubelet 硬拒（切 cgroup v2 后通过，见 7.4） |
| helm install（手动 T05） | 23 s | `--wait`：Chart 渲染 → 镜像拉取（ghcr 经 CN 镜像）→ Pod Ready |
| Argo CD 安装 → 全组件 Ready | ≈1 min | apply → 容器运行 ≈30 s（含 quay.io 镜像拉取）→ 四组件全部 Ready；实际占用 87 Mi（请求 352 Mi 起步，远低于 700 Mi 关注线） |
| Git 提交推送 → Argo 首次 Synced+Healthy | 60 s | `kubectl apply -f application.yaml` 起，含 repo clone + helm render + 部署 |
| Git 提交推送 → 副本数变更同步（2 副本） | 275 s | Argo 默认 3 min 轮询主导；selfHeal/prune 正常 |
| git revert push → Argo 同步完成 | ≈305 s | 12:30:18Z push → 12:35:22Z Synced（3 min 轮询 + render/sync）；重建的 HPA 无 stabilization 历史包袱，同步后立即回收至 1 副本 |

### 7.2 漂移恢复与回滚

| 演示 | 实测耗时 | 机制归因 |
| --- | --- | --- |
| `kubectl scale --replicas=2`（漂移） → 回到 1 | 323 s | Chart 在 autoscaling 启用时**不渲染** `spec.replicas`，Argo apply 无法删除该字段，实际回收由 HPA 执行（默认 300 s scale-down stabilization + 轮询），Argo 全程 Synced 并标记漂移 |
| git revert（values 副本数 2 → 自动扩缩恢复） → 回到 1 | ≈305 s | revert push → Argo 同步 ≈305 s；HPA 对象随 chart 重建（prune 语义），Deployment 交还 HPA 管理并立即回到 minReplicas=1 |

### 7.3 内存基线（free -m available）

| 时点 | 可用 (Mi) |
| --- | --- |
| K3s 安装前 | 3139 |
| K3s 组件就绪后（干净态） | 2560 |
| Argo CD 就绪后 | 1989 |
| 网关部署后（T05 手动 helm，含重启验证） | 2488–2881（区间含重启前后） |
| 全部就位终值（T11 复核） | 1899 |
| 护栏 | 800（未触发） |

### 7.4 环境适配记录（可复现性关键项）

| 项 | 结论 |
| --- | --- |
| cgroup v2 | K3s v1.37 kubelet 拒绝 cgroup v1 主机；GRUB 追加 `systemd.unified_cgroup_hierarchy=1` 后重启解决。重建 VM 必须携带该参数 |
| Pod → VM 数据实例连通 | docker 的 nat PREROUTING DNAT 先于 kube-router NetworkPolicy 求值，Pod 访问 192.168.137.10:6379/5432 被策略拒绝；已在 nat DOCKER 链顶部插入 `-s 10.42.0.0/16 -j RETURN`（systemd unit `k3s-docker-netpol-fix.service` 持久化），Pod 流量保持原始 dst 走 docker-proxy 用户态代理，策略按声明放行 |
| NetworkPolicy 反向验证 | 未放行目标（k3s API 6443、外网 TCP/53）从 Pod 内均被拒（≈0.02–0.07 s REJECT）；无 NetworkPolicy 覆盖的对照 Pod 可连通同一 6443，证明拦截来自策略而非端口未监听 |
| 镜像体积 | `ghcr.io/deltmchey/llm-secguard:385d63a04fb6` = 198 MB（多阶段构建，非 root） |
| 冒烟证据 | Pod 内 Redis PING=PONG、PG 就绪；NodePort /healthz 200；/v1/chat/completions 200 且带 `x-ratelimit-remaining`（限流链路经 Pod→VM Redis 全通）；audit_logs 行数 +1 |

## 附：变更记录

| 日期 | 内容 |
| --- | --- |
| 2026-11-04 | 初版：W2 环境规格、负载口径、10 轮压测矩阵实测数字（A/D p50/p95/p99/RPS、guard_latency 直方图、内存曲线）、红队口径与 [N]% 占位定档 |
| 2026-11-10 | 追加 §3.5：守卫补强后复测（llm-secguard c37bd6f，规则 18→20）——VU20 D 单轮 p95=10.24ms / RPS 46.35 无回归，guard_latency 仍 µs 级（input 0.0316ms / output 0.0357ms），守卫 400 份额 7.32%→8.65%，promptfoo 自编集 34/36→36/36 |
| 2026-11-25 | 追加 §7：W3 基础设施实测（K3s v1.37.2+k3s1 / Argo CD v3.6.3 / helm v4.3.2 / terraform 1.17.2+aws 6.74.0）——K3s 健康 ≈3min、helm 23s、Argo Ready ≈1min(87Mi)、首同步 60s、selfHeal 323s、镜像 198MB、内存全程高于护栏；§1 K3s 列回填（cgroup v2 与 docker DNAT×netpol 两条环境适配记录入档） |
