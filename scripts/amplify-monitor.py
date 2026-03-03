#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["boto3"]
# ///
"""
Amplify deployment monitor — NotOurGroceries
Usage: ./scripts/amplify-monitor.py
       ./scripts/amplify-monitor.py 5    # custom poll interval (seconds)
"""

import boto3, sys, time, os
from datetime import datetime, timezone

APP_ID = "d2rsreno8nimo5"
BRANCH = "main"
POLL   = int(sys.argv[1]) if len(sys.argv) > 1 else 10

# ── ANSI ──────────────────────────────────────────────────────────────────────
R   = '\033[0m'
BLD = '\033[1m'
DIM = '\033[2m'
GRN = '\033[32m'
YLW = '\033[33m'
RED = '\033[31m'
CYN = '\033[36m'
MAG = '\033[35m'

SPINNERS = ['⠋','⠙','⠹','⠸','⠼','⠴','⠦','⠧','⠇','⠏']
_spin_i  = 0

def spin():
    global _spin_i
    c = SPINNERS[_spin_i % len(SPINNERS)]
    _spin_i += 1
    return f'{YLW}{c}{R}'

def scol(s):
    return {
        'SUCCEED':      f'{GRN}SUCCEED{R}',
        'RUNNING':      f'{YLW}{BLD}RUNNING{R}',
        'FAILED':       f'{RED}{BLD}FAILED {R}',
        'PENDING':      f'{DIM}PENDING{R}',
        'PROVISIONING': f'{YLW}PROVSNG{R}',
        'CANCELLED':    f'{DIM}CANCELD{R}',
        'CANCELLING':   f'{YLW}CANCLLG{R}',
    }.get(s, f'{DIM}{s}{R}')

def sicon(s):
    return {
        'SUCCEED':      f'{GRN}✓{R}',
        'RUNNING':      f'{YLW}▶{R}',
        'FAILED':       f'{RED}✗{R}',
        'PENDING':      f'{DIM}·{R}',
        'PROVISIONING': f'{YLW}·{R}',
        'CANCELLED':    f'{DIM}✗{R}',
    }.get(s, ' ')

def hhmm(dt):
    if dt is None: return '--:--'
    return dt.astimezone().strftime('%H:%M')

def dur(start, end):
    if not start or not end: return ''
    d = int((end - start).total_seconds())
    return f'{d//60}m{d%60:02d}s'

def elapsed(start):
    if not start: return ''
    d = int((datetime.now(timezone.utc) - start).total_seconds())
    return f'{d//60}m{d%60:02d}s'

# ── Data fetch ─────────────────────────────────────────────────────────────────
def fetch(client):
    try:
        resp = client.list_jobs(appId=APP_ID, branchName=BRANCH, maxResults=5)
        jobs = resp.get('jobSummaries', [])
        detail = None
        if jobs:
            d = client.get_job(appId=APP_ID, branchName=BRANCH, jobId=jobs[0]['jobId'])
            detail = d.get('job', {})
        return jobs, detail, None
    except Exception as e:
        return [], None, str(e)

# ── Render ─────────────────────────────────────────────────────────────────────
W = 52

def draw(jobs, detail, err, countdown):
    lines = []
    now = datetime.now().strftime('%H:%M:%S')
    is_active = jobs and jobs[0].get('status') in ('RUNNING', 'PROVISIONING', 'PENDING')

    # Header
    sp = spin() if is_active else ' '
    lines.append(f'{CYN}{BLD} AMPLIFY MONITOR{R}  {DIM}{APP_ID} / {BRANCH}{R}')
    lines.append('─' * W)
    lines.append(f' {now}   {sp}  next refresh in {countdown}s')
    lines.append('')

    if err:
        lines.append(f' {RED}Error:{R} {DIM}{err[:W-8]}{R}')
    elif not jobs:
        lines.append(f' {DIM}No jobs found.{R}')
    else:
        # ── Latest job ──
        j      = jobs[0]
        jid    = j.get('jobId', '?')
        jstat  = j.get('status', '?')
        jstart = j.get('startTime')
        jend   = j.get('endTime')

        if jstat in ('RUNNING', 'PROVISIONING', 'PENDING'):
            tinfo = f'started {hhmm(jstart)}  elapsed {elapsed(jstart)}'
        else:
            tinfo = f'{hhmm(jstart)} → {hhmm(jend)}  {dur(jstart, jend)}'

        lines.append(f' {BLD}JOB #{jid}{R}   {scol(jstat)}')
        lines.append(f' {DIM}{tinfo}{R}')
        lines.append('')

        # ── Steps ──
        if detail:
            for step in detail.get('steps', []):
                sname  = step.get('stepName', '')
                sstat  = step.get('status', '')
                sstart = step.get('startTime')
                send   = step.get('endTime')
                ic     = sicon(sstat)
                sc     = scol(sstat)
                if sstat == 'RUNNING':
                    t = f'{DIM}{elapsed(sstart)}{R}'
                elif sstat == 'SUCCEED':
                    t = f'{DIM}{dur(sstart, send)}{R}'
                else:
                    t = ''
                lines.append(f'   {ic} {sname:<8} {sc}   {t}')

        # ── Recent jobs ──
        if len(jobs) > 1:
            lines.append('')
            lines.append(f' {DIM}recent{R}')
            for j2 in jobs[1:]:
                jid2   = j2.get('jobId', '?')
                jstat2 = j2.get('status', '?')
                js2    = j2.get('startTime')
                je2    = j2.get('endTime')
                ic     = sicon(jstat2)
                lines.append(
                    f'   {ic} #{jid2:<3}  {scol(jstat2)}  '
                    f'{DIM}{hhmm(js2)}→{hhmm(je2)}  {dur(js2,je2)}{R}'
                )

    lines.append('')
    lines.append('─' * W)
    out = '\033[2J\033[H' + '\n'.join(lines) + '\n'
    os.write(1, out.encode())

# ── Main ────────────────────────────────────────────────────────────────────────
def main():
    client = boto3.Session(profile_name='mine').client('amplify', region_name='us-east-1')

    sys.stdout.write('\033[?25l')   # hide cursor
    sys.stdout.flush()

    try:
        jobs, detail, err = fetch(client)

        while True:
            for countdown in range(POLL, 0, -1):
                draw(jobs, detail, err, countdown)
                time.sleep(1)
            jobs, detail, err = fetch(client)

    except KeyboardInterrupt:
        pass
    finally:
        sys.stdout.write('\033[?25h')   # restore cursor
        sys.stdout.write('\033[2J\033[H')
        sys.stdout.flush()

if __name__ == '__main__':
    main()
