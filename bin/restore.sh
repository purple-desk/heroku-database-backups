#!/bin/bash

# terminate script as soon as any command fails
set -e

echo "******* Starting restore to $DEST_APP"


function trimString()
{
    echo "${1}" | sed -e 's/^ *//g' -e 's/ *$//g'
}

function isEmptyString()
{
    if [[ "$(trimString ${1})" = '' ]]
    then
        echo 'true'
    else
        echo 'false'
    fi
}

function encodeURL()
{
    local length="${#1}"

    local i=0

    for ((i = 0; i < length; i++))
    do
        local walker="${1:i:1}"

        case "${walker}" in
            [a-zA-Z0-9.~_-])
                printf "${walker}"
                ;;
            ' ')
                printf +
                ;;
            *)
                printf '%%%X' "'${walker}"
                ;;
        esac
    done
}

function generateSignURL()
{
    local region="${1}"
    local bucket="${2}"
    local filePath="${3}"
    local awsAccessKeyID="${4}"
    local awsSecretAccessKey="${5}"
    local method="${6}"
    local minuteExpire="${7}"

    local endPoint="$("$(isEmptyString ${region})" = 'true' && echo 's3.amazonaws.com' || echo "s3-${region}.amazonaws.com")"
    local expire="$(($(date +%s) + ${minuteExpire} * 60))"
    local signature="$(echo -en "${method}\n\n\n${expire}\n/${bucket}/${filePath}" | \
                       openssl dgst -sha1 -binary -hmac "${awsSecretAccessKey}" | \
                       openssl base64)"
    local query="AWSAccessKeyId=$(encodeURL "${awsAccessKeyID}")&Expires=${expire}&Signature=$(encodeURL "${signature}")"

    echo "https://${endPoint}/${bucket}/${filePath}?${query}"
}

# If a "DoW" argument exists and the current day of week doesn't match it, exit.
# 0-6, 0 is Sunday
CURR_DOW=$(date +"%w")
if ! [[ -z "$DOW" ]] && ! [[ "$DOW" =~ $CURR_DOW ]] ; then
  echo "Current Day of Week doesn't match the DOW argument"
  exit 0
fi

if [[ -z "$SRC_APP" ]]; then
  echo "Missing SRC_APP variable which must be set to the name of the app that the DB was backed-up from"
  exit 1
fi

if [[ -z "$DEST_APP" ]]; then
  echo "Missing DEST_APP variable which must be set to the name of your app that the DB should be restored to"
  exit 1
fi

if [[ "$DEST_APP" =~ "prod" ]]; then
  echo "Prod shouldn't be part of the destination app"
  exit 1
fi

if [[ -z "$" ]]; then
  echo "Missing DEST_APP variable which must be set to the name of your app that the DB should be restored to"
  exit 1
fi

if [[ -z "$DATABASE" ]]; then
  echo "Missing DATABASE variable which must be set to the name of the DATABASE you would like to restore"
  exit 1
fi

if [[ -z "$S3_BUCKET_PATH" ]]; then
  echo "Missing S3_BUCKET_PATH variable which must be set the directory in s3 where you would like to restore your database backups from"
  exit 1
fi

# Install AWS CLI
curl https://s3.amazonaws.com/aws-cli/awscli-bundle.zip -o awscli-bundle.zip
unzip awscli-bundle.zip
chmod +x ./awscli-bundle/install
./awscli-bundle/install -i /tmp/aws

# Get the latest backup filename from S3
BACKUP_FILE_NAME=$(/tmp/aws/bin/aws s3 ls s3://$S3_BUCKET_PATH/$SRC_APP/$DATABASE/$(date +"%Y-%m-%d") | tail -1 | awk -F" " '{print $NF}')

# Copy the file from S3 to the local disk
/tmp/aws/bin/aws s3 cp s3://$S3_BUCKET_PATH/$SRC_APP/$DATABASE/$BACKUP_FILE_NAME /tmp/latest.dump.gz

# Unzip
gzip -d /tmp/latest.dump.gz

# Copy the file to a temp folder on S3
/tmp/aws/bin/aws s3 cp /tmp/latest.dump s3://$S3_BUCKET_PATH/temp/latest.dump

# Generate a signed URL to get the file.
RESTORE_FILE_URL=$(generateSignURL "" "$S3_BUCKET_PATH" "temp/latest.dump" "$AWS_ACCESS_KEY_ID" "$AWS_SECRET_ACCESS_KEY" "GET" "5")

# Restore the target database using the DB file.
/app/vendor/heroku-toolbelt/bin/heroku pg:backups restore "$RESTORE_FILE_URL" DATABASE_URL --confirm $DEST_APP --app $DEST_APP

# Run outstanding migrations if there are any.
/app/vendor/heroku-toolbelt/bin/heroku run python eduapi/manage.py migrate --app $DEST_APP

# Delete the temporary file.
/tmp/aws/bin/aws s3 rm s3://$S3_BUCKET_PATH/temp/latest.dump

echo "******* Restore $BACKUP_FILE_NAME to $DEST_APP complete"

