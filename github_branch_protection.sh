#!/bin/bash

if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <github_username> <github_token>"
    exit 1
fi

USERNAME="$1"
TOKEN="$2"

# 获取用户所有仓库（包括详细信息）
echo "Getting repositories for $USERNAME..."
TEMP_FILE=$(mktemp)
curl -s -H "Authorization: token $TOKEN" \
    "https://api.github.com/users/$USERNAME/repos?per_page=100" > "$TEMP_FILE"

# 显示仓库列表和保护状态
echo -e "\nAvailable repositories:"
echo "----------------------------------------"
echo "ID | Repository | Default Branch | Protection Status"
echo "----------------------------------------"

# 读取并显示仓库信息
i=1
jq -r '.[] | "\(.name)\t\(.default_branch)"' "$TEMP_FILE" | while IFS=$'\t' read -r repo default_branch; do
    if [ -n "$repo" ]; then
        # 获取分支保护状态
        protection_status=$(curl -s -H "Authorization: token $TOKEN" \
            -H "Accept: application/vnd.github.luke-cage-preview+json" \
            "https://api.github.com/repos/$USERNAME/$repo/branches/$default_branch/protection")
        
        # 分析保护状态
        if echo "$protection_status" | jq -e '.message' > /dev/null; then
            status="❌ Not Protected"
        else
            status="✓ Protected"
            # 检查保护强度
            reviews=$(echo "$protection_status" | jq -r '.required_pull_request_reviews // empty')
            if [ ! -z "$reviews" ]; then
                review_count=$(echo "$reviews" | jq -r '.required_approving_review_count // 0')
                status="$status (Reviews: $review_count)"
            fi
        fi
        
        printf "[%2d] %-30s %-15s %s\n" "$i" "$repo" "$default_branch" "$status"
        echo "$repo" >> "$TEMP_FILE.names"
        i=$((i+1))
    fi
done

echo -e "\nPlease select repositories (enter numbers separated by space, or 'all' for all repositories):"
read -r selection

# 处理用户选择
if [ "$selection" = "all" ]; then
    selected_repos=$(cat "$TEMP_FILE.names")
else
    selected_repos=""
    for num in $selection; do
        if [ "$num" -gt 0 ] && [ "$num" -le "$i" ]; then
            selected_repo=$(sed -n "${num}p" "$TEMP_FILE.names")
            selected_repos="$selected_repos$selected_repo"$'\n'
        else
            echo "Invalid selection: $num"
        fi
    done
fi

# 处理选中的仓库
echo "$selected_repos" | while IFS= read -r repo; do
    if [ -n "$repo" ]; then
        echo -e "\nProcessing repository: $repo"
        
        # 从缓存中获取默认分支
        default_branch=$(jq -r ".[] | select(.name == \"$repo\") | .default_branch" "$TEMP_FILE")
        
        echo "Default branch: $default_branch"
        
        # 设置分支保护
        response=$(curl -s -X PUT \
            -H "Authorization: token $TOKEN" \
            -H "Accept: application/vnd.github.luke-cage-preview+json" \
            -H "Content-Type: application/json" \
            "https://api.github.com/repos/$USERNAME/$repo/branches/$default_branch/protection" \
            -d '{
                "required_status_checks": null,
                "enforce_admins": false,
                "required_pull_request_reviews": {
                    "dismiss_stale_reviews": true,
                    "require_code_owner_reviews": false,
                    "required_approving_review_count": 1
                },
                "restrictions": null,
                "allow_force_pushes": true,
                "allow_deletions": false
            }')
        
        if [ $? -eq 0 ]; then
            echo "✓ Successfully protected $repo's $default_branch branch"
        else
            echo "Error: Failed to protect $repo's $default_branch branch"
            echo "Trying simplified configuration..."
            
            # 尝试简化配置
            response=$(curl -s -X PUT \
                -H "Authorization: token $TOKEN" \
                -H "Accept: application/vnd.github.luke-cage-preview+json" \
                -H "Content-Type: application/json" \
                "https://api.github.com/repos/$USERNAME/$repo/branches/$default_branch/protection" \
                -d '{
                    "required_status_checks": null,
                    "enforce_admins": false,
                    "required_pull_request_reviews": null,
                    "restrictions": null,
                    "allow_force_pushes": true,
                    "allow_deletions": false
                }')
            
            if [ $? -eq 0 ]; then
                echo "✓ Successfully protected $repo's $default_branch branch with simplified config"
            else
                echo "Error: Failed to protect $repo's $default_branch branch with simplified config"
            fi
        fi
    fi
done

# 清理临时文件
rm -f "$TEMP_FILE" "$TEMP_FILE.names"
