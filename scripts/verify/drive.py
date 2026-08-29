import sys,time,Quartz
sys.path.insert(0,'/private/tmp/claude-501/-Users-daniel/7d21c71b-fd43-4eaa-9f7e-78ab8da348b0/scratchpad/ef/scripts/verify')
from ax import *
PID=24917
def win():
    a=AXUIElementCreateApplication(PID)
    return (attr(a,'AXWindows'))[0]
def all_elems():
    return walk(win())
def find(role=None, text=None):
    out=[]
    for e in all_elems():
        if role and attr(e,'AXRole')!=role: continue
        blob=' '.join(str(x) for x in (attr(e,'AXTitle'),attr(e,'AXDescription'),attr(e,'AXValue')) if x)
        if text and text not in blob: continue
        out.append(e)
    return out
def press(role,text):
    es=find(role,text)
    if not es: print('MISS',role,text); return False
    print('press',text,AXUIElementPerformAction(es[0],'AXPress')); return True
def key(code,flags=0,n=1):
    for _ in range(n):
        for down in (True,False):
            ev=Quartz.CGEventCreateKeyboardEvent(None,code,down)
            Quartz.CGEventSetFlags(ev,flags)
            Quartz.CGEventPostToPid(PID,ev)
        time.sleep(0.01)
def typestr(text):
    for ch in text:
        for down in (True,False):
            ev=Quartz.CGEventCreateKeyboardEvent(None,0,down)
            Quartz.CGEventKeyboardSetUnicodeString(ev,len(ch),ch)
            Quartz.CGEventPostToPid(PID,ev)
        time.sleep(0.012)
def settext(field,val):
    AXUIElementSetAttributeValue(field,'AXFocused',True); time.sleep(0.3)
    key(124,n=40); key(51,n=40); time.sleep(0.2)
    typestr(val); time.sleep(0.2)
def dump():
    for e in all_elems():
        r=attr(e,'AXRole')
        if r in ('AXButton','AXCheckBox','AXTextField','AXStaticText','AXRadioButton','AXPopUpButton','AXSegmentedControl','AXIncrementor'):
            print(r, repr(attr(e,'AXTitle')), repr(attr(e,'AXDescription')), repr(attr(e,'AXValue')))
from ApplicationServices import AXValueGetValue, kAXValueCGPointType, kAXValueCGSizeType
def clickel(e):
    ok,pt=AXValueGetValue(attr(e,'AXPosition'),kAXValueCGPointType,None)
    ok2,sz=AXValueGetValue(attr(e,'AXSize'),kAXValueCGSizeType,None)
    x=pt.x+sz.width/2; y=pt.y+sz.height/2
    for t in (Quartz.kCGEventLeftMouseDown,Quartz.kCGEventLeftMouseUp):
        ev=Quartz.CGEventCreateMouseEvent(None,t,(x,y),Quartz.kCGMouseButtonLeft)
        Quartz.CGEventPostToPid(PID,ev); time.sleep(0.05)
def retry_find(role,text,tries=8):
    for _ in range(tries):
        try:
            es=find(role,text)
            if es: return es[0]
        except Exception: pass
        time.sleep(0.5)
    return None
def clickon(role,text):
    e=retry_find(role,text)
    if e is None: print('MISS',text); return False
    clickel(e); print('clicked',text); return True
