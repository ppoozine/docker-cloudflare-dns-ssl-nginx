#!/bin/bash

# Nginx日誌上傳至AWS CloudWatch腳本
# 此腳本將Nginx日誌上傳至AWS CloudWatch Logs
# 需要AWS CLI已安裝並配置好權限

# 設置變數
DOCKER_COMPOSE_DIR="/path/to/your/nginx-service"
LOG_GROUP_NAME="/nginx/production"      # CloudWatch日誌群組名稱
LOG_STREAM_PREFIX="nginx-"             # CloudWatch日誌串流前綴
AWS_REGION="ap-northeast-1"            # AWS區域，根據需要修改

# 確保AWS CLI已安裝
if ! command -v aws &> /dev/null; then
    echo "錯誤: AWS CLI未安裝，請安裝後再執行此腳本"
    echo "安裝指令: pip install awscli"
    exit 1
fi

echo "[$(date '+%Y-%m-%d %H:%M:%S')] 開始上傳Nginx日誌至CloudWatch..."

# 檢查日誌群組是否存在，如果不存在則創建
aws logs describe-log-groups --log-group-name-prefix ${LOG_GROUP_NAME} --region ${AWS_REGION} | grep ${LOG_GROUP_NAME} > /dev/null
if [ $? -ne 0 ]; then
    echo "創建日誌群組 ${LOG_GROUP_NAME}..."
    aws logs create-log-group --log-group-name ${LOG_GROUP_NAME} --region ${AWS_REGION}
    # 設置日誌保留期 (30天)
    aws logs put-retention-policy --log-group-name ${LOG_GROUP_NAME} --retention-in-days 30 --region ${AWS_REGION}
fi

# 從Nginx容器獲取日誌
TEMP_DIR=$(mktemp -d)
LOG_STREAM_NAME="${LOG_STREAM_PREFIX}$(date +%Y-%m-%d-%H)"

# 檢查Nginx容器是否運行
if docker ps | grep -q nginx; then
    echo "從Nginx容器複製日誌..."

    # 複製訪問日誌
    docker cp nginx:/var/log/nginx/access.log ${TEMP_DIR}/access.log

    # 複製錯誤日誌
    docker cp nginx:/var/log/nginx/error.log ${TEMP_DIR}/error.log

    # 上傳訪問日誌到CloudWatch
    if [ -f ${TEMP_DIR}/access.log ] && [ -s ${TEMP_DIR}/access.log ]; then
        echo "上傳訪問日誌到CloudWatch..."
        aws logs create-log-stream --log-group-name ${LOG_GROUP_NAME} --log-stream-name "${LOG_STREAM_NAME}-access" --region ${AWS_REGION} || true

        # 使用timestamp作為序列token
        SEQ_TOKEN=""
        NEXT_TOKEN=$(aws logs describe-log-streams --log-group-name ${LOG_GROUP_NAME} --log-stream-name-prefix "${LOG_STREAM_NAME}-access" --region ${AWS_REGION} --query 'logStreams[0].uploadSequenceToken' --output text)

        if [ "$NEXT_TOKEN" != "None" ] && [ "$NEXT_TOKEN" != "" ]; then
            SEQ_TOKEN="--sequence-token $NEXT_TOKEN"
        fi

        # 上傳日誌行
        TIMESTAMP=$(date +%s000)
        aws logs put-log-events --log-group-name ${LOG_GROUP_NAME} --log-stream-name "${LOG_STREAM_NAME}-access" \
            --log-events timestamp=${TIMESTAMP},message="$(cat ${TEMP_DIR}/access.log | tr '\n' '\\n')" \
            ${SEQ_TOKEN} --region ${AWS_REGION}
    fi

    # 上傳錯誤日誌到CloudWatch
    if [ -f ${TEMP_DIR}/error.log ] && [ -s ${TEMP_DIR}/error.log ]; then
        echo "上傳錯誤日誌到CloudWatch..."
        aws logs create-log-stream --log-group-name ${LOG_GROUP_NAME} --log-stream-name "${LOG_STREAM_NAME}-error" --region ${AWS_REGION} || true

        # 使用timestamp作為序列token
        SEQ_TOKEN=""
        NEXT_TOKEN=$(aws logs describe-log-streams --log-group-name ${LOG_GROUP_NAME} --log-stream-name-prefix "${LOG_STREAM_NAME}-error" --region ${AWS_REGION} --query 'logStreams[0].uploadSequenceToken' --output text)

        if [ "$NEXT_TOKEN" != "None" ] && [ "$NEXT_TOKEN" != "" ]; then
            SEQ_TOKEN="--sequence-token $NEXT_TOKEN"
        fi

        # 上傳日誌行
        TIMESTAMP=$(date +%s000)
        aws logs put-log-events --log-group-name ${LOG_GROUP_NAME} --log-stream-name "${LOG_STREAM_NAME}-error" \
            --log-events timestamp=${TIMESTAMP},message="$(cat ${TEMP_DIR}/error.log | tr '\n' '\\n')" \
            ${SEQ_TOKEN} --region ${AWS_REGION}
    fi
else
    echo "Nginx容器未運行，無法獲取日誌"
fi

# 清理臨時文件
rm -rf ${TEMP_DIR}

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Nginx日誌上傳完成!"
exit 0