"""
NexOps housekeeping Lambda.

Triggered daily via EventBridge. Placeholder for scheduled
maintenance tasks (e.g. cleaning up stale objects in the
uploads bucket). Extend this as real requirements come in.
"""

import json
import logging

logger = logging.getLogger()
logger.setLevel(logging.INFO)


def handler(event, context):
    logger.info("NexOps housekeeping run started: %s", json.dumps(event))

    # TODO: add real housekeeping logic here.

    logger.info("NexOps housekeeping run completed.")
    return {"statusCode": 200, "body": "ok"}
