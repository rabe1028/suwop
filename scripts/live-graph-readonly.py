#!/usr/bin/env -S uv run --no-project --script
"""Emit owner-filtered read-only fixture SQL or check its result; no DB connection."""

import argparse
import json
import sys
import uuid
from pathlib import Path


def identities(report):
    owner = str(uuid.UUID(report["fixtureOwnerID"]))
    motion = str(uuid.UUID(report["fixtureMotionID"]))
    resources = report["observations"][0]["resources"]
    parents = {str(uuid.UUID(r["fixtureAssetID"])) for r in resources if r["role"] in {"P", "P2"}}
    if len(parents) != 2:
        raise ValueError("two fixture parents required")
    final_motion = next(r for r in report["observations"][-1]["resources"] if r["role"] == "M")
    if final_motion["fixtureAssetID"] != motion or not final_motion["forwardMotionNull"]:
        raise ValueError("API final motion identity mismatch")
    final_video = next(r for r in report["observations"][-1]["resources"] if r["role"] == "V")
    video = str(uuid.UUID(final_video["fixtureAssetID"]))
    if not final_video["forwardMotionNull"]:
        raise ValueError("API final standalone video must have forward null")
    return owner, motion, parents, final_motion["visibility"], video, final_video["visibility"]


def query(owner, motion, video):
    # psql binds canonical UUID variables; the read-only SQL itself is constant.
    print(f"\\set owner {owner}")
    print(f"\\set motion {motion}")
    print(f"\\set video {video}")
    print("""
BEGIN READ ONLY;
SET LOCAL statement_timeout = '5s';
SELECT coalesce(json_agg(json_build_object(
  'id', id, 'ownerId', "ownerId", 'motionId', "livePhotoVideoId",
  'visibility', visibility, 'type', type)), '[]'::json)
FROM asset
WHERE "ownerId" = :'owner'::uuid
  AND (id IN (:'motion'::uuid, :'video'::uuid)
       OR "livePhotoVideoId" IN (:'motion'::uuid, :'video'::uuid));
ROLLBACK;
""")


def check(rows, owner, motion, expected, expected_visibility, video, video_visibility):
    if not all(row["ownerId"] == owner for row in rows):
        raise ValueError("owner-filtered control mismatch")
    parents = {row["id"] for row in rows if row["motionId"] == motion}
    if parents != expected:
        raise ValueError("API fixture parents differ from database control")
    if any(row["type"] != "IMAGE" for row in rows if row["id"] in expected):
        raise ValueError("reverse parents must be IMAGE fixtures")
    motion_rows = [row for row in rows if row["id"] == motion]
    if len(motion_rows) != 1 or motion_rows[0]["type"] != "VIDEO":
        raise ValueError("motion control mismatch")
    if (
        motion_rows[0]["motionId"] is not None
        or motion_rows[0]["visibility"] != expected_visibility
    ):
        raise ValueError("API/database final motion observation differs")
    video_parents = {row["id"] for row in rows if row["motionId"] == video}
    video_rows = [row for row in rows if row["id"] == video]
    if video_parents or len(video_rows) != 1:
        raise ValueError("standalone fixture reverse edge control mismatch")
    if (
        video_rows[0]["type"] != "VIDEO"
        or video_rows[0]["motionId"] is not None
        or video_rows[0]["visibility"] != video_visibility
    ):
        raise ValueError("API/database standalone fixture observation differs")
    print(
        json.dumps(
            {
                "readOnlyControl": True,
                "ownerFilterApplied": True,
                "knownFixtureParentsMatch": True,
                "finalMotionVisibilityMatchesAPI": True,
                "fixtureReverseParentCount": len(parents),
                "standaloneFixtureReverseParentCount": len(video_parents),
                "standaloneFixtureVisibilityMatchesAPI": True,
                "motionVisibility": motion_rows[0]["visibility"],
                "universalConcurrentAbsenceProven": False,
            }
        )
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report", required=True, type=Path)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--query", action="store_true")
    mode.add_argument("--result", type=Path)
    args = parser.parse_args()
    try:
        owner, motion, parents, visibility, video, video_visibility = identities(
            json.loads(args.report.read_text())
        )
        if args.query:
            query(owner, motion, video)
        else:
            check(
                json.loads(args.result.read_text()),
                owner,
                motion,
                parents,
                visibility,
                video,
                video_visibility,
            )
    except (KeyError, ValueError, OSError, StopIteration, TypeError):
        print("read-only graph control failed; no credentials or raw SQL logged", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
