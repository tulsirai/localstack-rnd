import json
import os
import uuid

import boto3

dynamodb = boto3.resource("dynamodb")


def handler(event, context):
    table = dynamodb.Table(os.environ["TABLE_NAME"])
    method = event.get("requestContext", {}).get("http", {}).get("method", "GET")

    # Function URL POST, or direct invoke (e.g. Resource Browser) with a message
    if method == "POST" or "message" in event:
        data = json.loads(event.get("body", "{}")) if method == "POST" else event
        item = {"id": str(uuid.uuid4()), **data}
        table.put_item(Item=item)
        return {"statusCode": 200, "body": json.dumps(item)}

    result = table.scan()
    return {"statusCode": 200, "body": json.dumps(result["Items"])}
