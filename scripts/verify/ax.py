import sys,time,subprocess
from ApplicationServices import *
def attr(e,a):
    err,v=AXUIElementCopyAttributeValue(e,a,None); return v
def walk(e,depth=0,out=None):
    out=[] if out is None else out
    out.append(e)
    ch=attr(e,'AXChildren') or []
    for c in ch: walk(c,depth+1,out)
    return out
def app(name):
    pid=int(subprocess.check_output(['pgrep','-f',name]).split()[0]); return AXUIElementCreateApplication(pid)
def elems(name,role=None):
    a=app(name); w=(attr(a,'AXWindows') or [None])[0]
    return [e for e in walk(w) if role is None or attr(e,'AXRole')==role]
def desc(e): return (attr(e,'AXRole'),attr(e,'AXTitle'),attr(e,'AXDescription'),attr(e,'AXValue'),attr(e,'AXIdentifier'))
if __name__=='__main__':
    for e in elems(sys.argv[1]):
        d=desc(e)
        if d[0] in ('AXTextField','AXButton','AXStaticText','AXSecureTextField','AXRadioButton','AXTabGroup','AXCheckBox'): print(d)
