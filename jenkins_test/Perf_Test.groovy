/**
 * Perf_Test.groovy - TensorRT-LLM 性能测试 Pipeline
 * 
 * 功能：
 * - 支持三种测试模式: single-agg, multi-agg, disagg
 * - 集成 jenkins_test/scripts/ 的实现
 * - 支持多集群配置 (GB200, GB300, etc.)
 * 
 * 基于 gitlab-ci/ 的架构设计，适配 Jenkins 环境
 */

// ============================================
// Pipeline 参数
// ============================================
properties([
    parameters([
        choice(
            name: 'TESTLIST',
            choices: [
                // 🌟 TestList 模式（推荐）
                'gb200_unified_suite',
                'gb300_unified_suite',
                
                // 手动调试模式
                'manual'
            ],
            description: '''选择测试模式:
  - TestList: 从 YAML 文件运行测试（推荐）
  - manual: 手动指定配置文件调试单个测试'''
        ),
        choice(
            name: 'FILTER_MODE',
            choices: ['all', 'single-agg', 'multi-agg', 'disagg'],
            description: '''测试类型过滤（TestList 模式）:
  - all: 运行所有类型的测试
  - single-agg: 仅运行单节点聚合测试
  - multi-agg: 仅运行多节点聚合测试
  - disagg: 仅运行分离式测试'''
        ),
        choice(
            name: 'PYTEST_K',
            defaultValue: '',
            description: '''pytest -k 过滤表达式（可选）
示例: "deepseek" 或 "deepseek and not fp8" 或 "llama or qwen"
留空则运行所有测试
注意：仅支持 single-agg 和 multi-agg 模式，disagg 模式不支持'''
        ),
        choice(
            name: 'CLUSTER',
            choices: ['gb300', 'gb200', 'gb200_lyris', 'local'],
            description: '''目标集群:
  - gb300: Lyris GB300 分区 (本地执行)
  - gb200: Selene GB200 分区 (SSH执行)
  - gb200_lyris: Lyris GB200 分区 (本地执行)
  - local: 本地开发测试'''
        ),
        string(
            name: 'CONFIG_FILE',
            defaultValue: '',
            description: '[手动模式] 配置文件名 (仅当 TESTLIST=manual 时使用)，例如: deepseek_r1_fp4_v2_blackwell'
        ),
        choice(
            name: 'MANUAL_TEST_MODE',
            choices: ['single-agg', 'multi-agg', 'disagg'],
            description: '[手动模式] 测试模式 (仅当 TESTLIST=manual 时使用)'
        ),
        string(
            name: 'TRTLLM_REPO',
            defaultValue: 'https://github.com/NVIDIA/TensorRT-LLM.git',
            description: 'TensorRT-LLM 仓库地址'
        ),
        string(
            name: 'TRTLLM_BRANCH',
            defaultValue: 'main',
            description: 'TensorRT-LLM 分支名称'
        ),
        string(
            name: 'DOCKER_IMAGE',
            defaultValue: '',
            description: 'Docker 镜像 (可选，留空则自动获取)'
        ),
        booleanParam(
            name: 'DRY_RUN',
            defaultValue: false,
            description: '试运行模式（仅显示将执行的操作）'
        )
    ])
])

// ============================================
// Pipeline 主流程
// ============================================
pipeline {
    agent any
    
    options {
        timestamps()
        timeout(time: 6, unit: 'HOURS')
        buildDiscarder(logRotator(numToKeepStr: '30'))
        disableConcurrentBuilds()
    }
    
    environment {
        // 工作目录
        WORKSPACE_ROOT = "${WORKSPACE}"
        TRTLLM_DIR = "${WORKSPACE}/TensorRT-LLM"
        SCRIPTS_DIR = "${WORKSPACE}/jenkins_test/scripts"
        TESTLISTS_DIR = "${WORKSPACE}/jenkins_test/testlists"
        
        // 用户参数
        TESTLIST = "${params.TESTLIST}"
        FILTER_MODE = "${params.FILTER_MODE}"
        PYTEST_K = "${params.PYTEST_K}"
        CLUSTER = "${params.CLUSTER}"
        CONFIG_FILE = "${params.CONFIG_FILE}"
        MANUAL_TEST_MODE = "${params.MANUAL_TEST_MODE}"
        TRTLLM_REPO = "${params.TRTLLM_REPO}"
        TRTLLM_BRANCH = "${params.TRTLLM_BRANCH}"
        DOCKER_IMAGE = "${params.DOCKER_IMAGE}"
        DRY_RUN = "${params.DRY_RUN}"
    }
    
    stages {
        // ========================================
        // Stage 1: 参数验证和模式识别
        // ========================================
        stage('参数验证和模式识别') {
            steps {
                script {
                    echo "=" * 80
                    echo "TensorRT-LLM 性能测试 Pipeline"
                    echo "=" * 80
                    echo "模式: ${TESTLIST}"
                    echo "目标集群: ${CLUSTER}"
                    if (PYTEST_K) {
                        echo "pytest -k 过滤: ${PYTEST_K}"
                    }
                    echo "TensorRT-LLM 仓库: ${TRTLLM_REPO}"
                    echo "TensorRT-LLM 分支: ${TRTLLM_BRANCH}"
                    echo "Docker 镜像: ${DOCKER_IMAGE ?: '自动获取'}"
                    echo "试运行: ${DRY_RUN}"
                    echo "=" * 80
                    
                    // 判断运行模式
                    if (TESTLIST == 'manual') {
                        // 手动调试模式：直接调用单独的脚本
                        env.USE_TESTLIST = 'false'
                        env.TEST_MODE = MANUAL_TEST_MODE
                        
                        if (!CONFIG_FILE) {
                            error "手动模式需要指定 CONFIG_FILE"
                        }
                        
                        echo "运行模式: 手动调试"
                        echo "测试类型: ${env.TEST_MODE}"
                        echo "配置文件: ${CONFIG_FILE}"
                        
                    } else {
                        // TestList 模式：使用统一的 run_perf_tests.sh
                        env.USE_TESTLIST = 'true'
                        env.TESTLIST_FILE = "${TESTLISTS_DIR}/${TESTLIST}.yml"
                        
                        echo "运行模式: TestList"
                        echo "TestList 文件: ${env.TESTLIST_FILE}"
                        echo "测试过滤: ${FILTER_MODE}"
                    }
                    
                    echo "=" * 80
                }
            }
        }
        
        // ========================================
        // Stage 2: 准备工作环境
        // ========================================
        stage('准备工作环境') {
            steps {
                script {
                    echo "准备工作环境..."
                    
                    // 克隆或更新 TensorRT-LLM 仓库
                    if (fileExists("${TRTLLM_DIR}")) {
                        echo "TensorRT-LLM 目录已存在，更新..."
                        dir("${TRTLLM_DIR}") {
                            sh """
                                git fetch origin
                                git checkout ${TRTLLM_BRANCH}
                                git pull origin ${TRTLLM_BRANCH}
                            """
                        }
                    } else {
                        echo "克隆 TensorRT-LLM 仓库..."
                        sh """
                            git clone --depth 1 --branch ${TRTLLM_BRANCH} ${TRTLLM_REPO} ${TRTLLM_DIR}
                        """
                    }
                    
                    // 验证必要文件存在
                    def requiredPaths = []
                    
                    if (TEST_MODE == 'disagg') {
                        requiredPaths = [
                            "${TRTLLM_DIR}/jenkins/scripts/perf/disaggregated/submit.py",
                            "${TRTLLM_DIR}/tests/integration/test_lists",
                            "${SCRIPTS_DIR}/run_disagg_test.sh",
                            "${SCRIPTS_DIR}/calculate_hardware_nodes.py"
                        ]
                    } else {
                        requiredPaths = [
                            "${TRTLLM_DIR}/tests/integration/defs/perf/test_perf_sanity.py",
                            TEST_MODE == 'single-agg' 
                                ? "${SCRIPTS_DIR}/run_single_agg_test.sh"
                                : "${SCRIPTS_DIR}/run_multi_agg_test.sh"
                        ]
                    }
                    
                    // 通用脚本
                    requiredPaths.add("${SCRIPTS_DIR}/lib/load_cluster_config.sh")
                    requiredPaths.add("${SCRIPTS_DIR}/lib/remote.sh")
                    requiredPaths.add("${SCRIPTS_DIR}/config/clusters.conf")
                    
                    for (path in requiredPaths) {
                        if (!fileExists(path)) {
                            error "必要文件不存在: ${path}"
                        }
                    }
                    
                    echo "✓ 工作环境准备完成"
                }
            }
        }
        
        // ========================================
        // Stage 3: 加载集群配置
        // ========================================
        stage('加载集群配置') {
            steps {
                script {
                    echo "加载集群配置: ${CLUSTER}"
                    
                    // 加载集群配置
                    def configScript = """
                        source ${SCRIPTS_DIR}/lib/load_cluster_config.sh ${CLUSTER}
                        
                        echo "CLUSTER_NAME=\${CLUSTER_NAME}"
                        echo "CLUSTER_HOST=\${CLUSTER_HOST}"
                        echo "CLUSTER_USER=\${CLUSTER_USER}"
                        echo "CLUSTER_TYPE=\${CLUSTER_TYPE}"
                        echo "CLUSTER_PARTITION=\${CLUSTER_PARTITION}"
                        echo "CLUSTER_ACCOUNT=\${CLUSTER_ACCOUNT}"
                        echo "CLUSTER_STORAGE=\${CLUSTER_STORAGE}"
                        echo "CLUSTER_LLM_DATA=\${CLUSTER_LLM_DATA}"
                        echo "MPI_TYPE=\${MPI_TYPE}"
                        echo "EXTRA_SRUN_PARAMS=\${EXTRA_SRUN_PARAMS}"
                    """
                    
                    def configOutput = sh(script: configScript, returnStdout: true).trim()
                    
                    // 解析配置
                    def configMap = [:]
                    configOutput.split('\n').each { line ->
                        if (line.startsWith('✓')) {
                            echo line
                        } else {
                            def parts = line.split('=', 2)
                            if (parts.size() == 2) {
                                configMap[parts[0]] = parts[1]
                                env."${parts[0]}" = parts[1]
                            }
                        }
                    }
                    
                    // 设置 Docker 镜像
                    if (!DOCKER_IMAGE) {
                        env.DOCKER_IMAGE = configMap['DOCKER_IMAGE'] ?: 'nvcr.io/nvidia/tensorrt-llm:latest'
                    }
                    
                    echo "✓ 集群配置加载完成"
                }
            }
        }
        
        // ========================================
        // Stage 4: 运行测试
        // ========================================
        stage('运行测试') {
            steps {
                script {
                    echo "开始执行测试..."
                    
                    def testScript = ""
                    def scriptArgs = []
                    
                    if (env.USE_TESTLIST == 'true') {
                        // =====================================
                        // TestList 模式：使用统一脚本
                        // =====================================
                        testScript = "${SCRIPTS_DIR}/run_perf_tests.sh"
                        scriptArgs = [
                            "--testlist", env.TESTLIST_FILE,
                            "--trtllm-dir", TRTLLM_DIR
                        ]
                        
                        // 添加过滤模式
                        if (FILTER_MODE != 'all') {
                            scriptArgs += ["--mode", FILTER_MODE]
                        }
                        
                        // 添加 pytest -k 过滤
                        if (PYTEST_K) {
                            scriptArgs += ["-k", PYTEST_K]
                        }
                        
                    } else {
                        // =====================================
                        // 手动调试模式：调用单独脚本
                        // =====================================
                        if (env.TEST_MODE == 'disagg') {
                            testScript = "${SCRIPTS_DIR}/run_disagg_test.sh"
                            scriptArgs = [
                                "--config-file", CONFIG_FILE,
                                "--trtllm-dir", TRTLLM_DIR,
                                "--workspace", "${WORKSPACE}/disagg_workspace"
                            ]
                        } else if (env.TEST_MODE == 'single-agg') {
                            testScript = "${SCRIPTS_DIR}/run_single_agg_test.sh"
                            scriptArgs = [
                                "--config-file", CONFIG_FILE,
                                "--trtllm-dir", TRTLLM_DIR
                            ]
                        } else if (env.TEST_MODE == 'multi-agg') {
                            testScript = "${SCRIPTS_DIR}/run_multi_agg_test.sh"
                            scriptArgs = [
                                "--config-file", CONFIG_FILE,
                                "--trtllm-dir", TRTLLM_DIR,
                                "--workspace", "${WORKSPACE}/multi_agg_workspace"
                            ]
                        }
                        
                        // 添加 pytest -k 过滤
                        if (PYTEST_K) {
                            scriptArgs += ["-k", PYTEST_K]
                        }
                    }
                    
                    // 添加 dry-run 标志
                    if (DRY_RUN == 'true') {
                        scriptArgs += ["--dry-run"]
                    }
                    
                    // 构造完整命令
                    def cmd = "${testScript} ${scriptArgs.join(' ')}"
                    
                    echo ""
                    echo "执行命令:"
                    echo "  ${cmd}"
                    echo ""
                    
                    // 执行测试脚本
                    def result = sh(
                        script: """
                            # 导出集群配置环境变量
                            export CLUSTER_ACCOUNT='${env.CLUSTER_ACCOUNT}'
                            export CLUSTER_PARTITION='${env.CLUSTER_PARTITION}'
                            export CLUSTER_LLM_DATA='${env.CLUSTER_LLM_DATA}'
                            export DOCKER_IMAGE='${env.DOCKER_IMAGE}'
                            export MPI_TYPE='${env.MPI_TYPE}'
                            export CLUSTER_HOST='${env.CLUSTER_HOST}'
                            export CLUSTER_USER='${env.CLUSTER_USER}'
                            export CLUSTER_TYPE='${env.CLUSTER_TYPE}'
                            export CLUSTER_NAME='${env.CLUSTER_NAME}'
                            
                            # 执行测试脚本
                            ${cmd}
                        """,
                        returnStatus: true
                    )
                    
                    if (result != 0) {
                        error "测试执行失败，退出码: ${result}"
                    }
                    
                    echo "✓ 测试执行完成"
                }
            }
        }
    }
    
    // ========================================
    // Post Actions
    // ========================================
    post {
        always {
            script {
                echo ""
                echo "=" * 80
                echo "Pipeline 执行完成"
                echo "=" * 80
                
                def mode = env.USE_TESTLIST == 'true' ? 'TestList' : '手动调试'
                echo "运行模式: ${mode}"
                
                if (env.USE_TESTLIST == 'true') {
                    echo "TestList: ${TESTLIST}"
                    echo "测试过滤: ${FILTER_MODE}"
                } else {
                    echo "测试类型: ${env.TEST_MODE}"
                    echo "配置文件: ${CONFIG_FILE}"
                }
                
                echo "目标集群: ${CLUSTER}"
                echo "结果: ${currentBuild.result ?: 'SUCCESS'}"
                echo "耗时: ${currentBuild.durationString}"
                echo "=" * 80
            }
        }
        
        success {
            script {
                echo "✓ 测试成功完成"
            }
        }
        
        failure {
            script {
                echo "✗ 测试失败"
                
                // 尝试收集错误日志
                def logPaths = [
                    "${WORKSPACE}/disagg_workspace/slurm_*.log",
                    "${WORKSPACE}/multi_agg_workspace/*.log"
                ]
                
                for (pattern in logPaths) {
                    try {
                        def logs = sh(script: "ls ${pattern} 2>/dev/null || true", returnStdout: true).trim()
                        if (logs) {
                            echo "发现错误日志:"
                            echo logs
                        }
                    } catch (Exception e) {
                        // 忽略错误
                    }
                }
            }
        }
        
        cleanup {
            script {
                echo "清理临时文件..."
                
                // 可选：清理临时工作目录
                // sh "rm -rf ${WORKSPACE}/disagg_workspace ${WORKSPACE}/multi_agg_workspace"
            }
        }
    }
}
