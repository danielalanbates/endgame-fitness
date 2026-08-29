import sys,time,Quartz
def type_to_pid(pid,text):
    for ch in text:
        for down in (True,False):
            ev=Quartz.CGEventCreateKeyboardEvent(None,0,down)
            Quartz.CGEventKeyboardSetUnicodeString(ev,len(ch),ch)
            Quartz.CGEventPostToPid(pid,ev)
        time.sleep(0.01)
if __name__=='__main__': type_to_pid(int(sys.argv[1]),sys.argv[2])
