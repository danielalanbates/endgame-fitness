import sys; sys.path.insert(0,'/private/tmp/claude-501/-Users-daniel/7d21c71b-fd43-4eaa-9f7e-78ab8da348b0/scratchpad')
from ax import *
tfs=elems('EFbin','AXTextField'); bts=elems('EFbin','AXButton')
print(AXUIElementSetAttributeValue(tfs[0],'AXValue','ef-smoke-test@batesai.org'))
print(AXUIElementSetAttributeValue(tfs[1],'AXValue','smoketest-pass-123'))
time.sleep(0.5)
b=[x for x in bts if attr(x,'AXDescription')=='Sign in'][0]
print(attr(b,'AXEnabled'), AXUIElementPerformAction(b,'AXPress'))
