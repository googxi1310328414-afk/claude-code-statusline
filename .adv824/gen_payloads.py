import json
import os

def make_payload(desc, ntasks=1, columns=140):
    tasks = []
    for i in range(ntasks):
        tasks.append({
            "id": "t%d" % i,
            "name": "worker",
            "type": "general",
            "status": "running",
            "effort": "max",
            "model": "claude-sonnet-5",
            "tokenCount": 12345,
            "startTime": 1700000000,
            "description": desc
        })
    return {"columns": columns, "tasks": tasks}

short_desc = "Review the auth module for bugs now pls"[:40]
with open("payload_short40.json", "w", encoding="utf-8") as f:
    json.dump(make_payload(short_desc, ntasks=1), f, ensure_ascii=False)

cjk1000 = "审" * 1000
with open("payload_cjk1000_1task.json", "w", encoding="utf-8") as f:
    json.dump(make_payload(cjk1000, ntasks=1), f, ensure_ascii=False)

with open("payload_cjk1000_2task.json", "w", encoding="utf-8") as f:
    json.dump(make_payload(cjk1000, ntasks=2), f, ensure_ascii=False)

cjk500 = "审" * 500
with open("payload_cjk500_1task.json", "w", encoding="utf-8") as f:
    json.dump(make_payload(cjk500, ntasks=1), f, ensure_ascii=False)

cjk100 = "审" * 100
with open("payload_cjk100_1task.json", "w", encoding="utf-8") as f:
    json.dump(make_payload(cjk100, ntasks=1), f, ensure_ascii=False)

cjk5000 = "审" * 5000
with open("payload_cjk5000_1task.json", "w", encoding="utf-8") as f:
    json.dump(make_payload(cjk5000, ntasks=1), f, ensure_ascii=False)

cjk2000 = "审" * 2000
with open("payload_cjk2000_1task.json", "w", encoding="utf-8") as f:
    json.dump(make_payload(cjk2000, ntasks=1), f, ensure_ascii=False)

print("done")
for fn in ["payload_short40.json","payload_cjk1000_1task.json","payload_cjk1000_2task.json","payload_cjk500_1task.json","payload_cjk100_1task.json","payload_cjk5000_1task.json","payload_cjk2000_1task.json"]:
    print(fn, os.path.getsize(fn))
