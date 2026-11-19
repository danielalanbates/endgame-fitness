# Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
import json, asyncio, os, re
from pathlib import Path
from playwright.async_api import async_playwright
BASE='http://127.0.0.1:4318'
OUT=Path(__file__).resolve().parents[2]/'.local'/'screenshots';OUT.mkdir(exist_ok=True)
async def main():
 async with async_playwright() as pw:
  browser=await pw.chromium.launch(headless=True, executable_path=os.getenv("CHROME_EXECUTABLE"))
  page=await browser.new_page(viewport={'width':1440,'height':1000},service_workers='block')
  errors=[]
  page.on('pageerror',lambda e:errors.append(str(e)))
  await page.goto(BASE);await page.get_by_role('link',name='Continue with Google').wait_for()
  assert await page.get_by_role('link',name='Continue with Apple').count()==1
  assert '/api/auth/oauth/google' in await page.get_by_role('link',name='Continue with Google').get_attribute('href')
  assert '/api/auth/oauth/apple' in await page.get_by_role('link',name='Continue with Apple').get_attribute('href')
  await page.screenshot(path=str(OUT/'01-login-desktop.png'),full_page=True)
  await page.set_viewport_size({'width':390,'height':844});await page.screenshot(path=str(OUT/'02-login-mobile.png'),full_page=True)
  assert await page.evaluate('document.documentElement.scrollWidth <= innerWidth')
  user={'id':'test-batesai-user','display_name':'Test Adventurer','friend_code':'1234567890ABCDEF'}
  cloud={'state':None,'revision':0}
  async def route(r):
   name=r.request.url.split('/api/endgame/')[-1];method=r.request.method
   if name=='config':data={'providers':['google','apple'],'provider':'batesai-membership'}
   elif name=='me':data={'user':user}
   elif name=='state':
    if method=='PUT':body=r.request.post_data_json;cloud.update(state=body['state'],revision=cloud['revision']+1)
    data=cloud
   elif name=='social':data={'friends':[{'id':'friend','name':'Training Buddy','level':3,'sessions':8,'weeklyDays':2,'weeklySets':12}],'incoming':[{'id':'new-friend','name':'New Friend'}],'outgoing':[]}
   else:data={'ok':True}
   await r.fulfill(status=200,content_type='application/json',body=json.dumps(data))
  await page.route('**/api/endgame/**',route)
  await page.reload();await page.get_by_text('Make it yours',exact=True).wait_for()
  await page.locator('input[name=name]').fill('Ada')
  for key,value in dict(age=32,weight=150,height=65,bench=75,squat=100,deadlift=110).items():
   await page.locator(f'input[name="{key}"]').fill(str(value))
  await page.locator('input[name=accepted]').check()
  await page.get_by_role('button',name='Build my program').click()
  await page.get_by_role('heading',name='Ready for your next level, Ada?').wait_for()
  assert await page.evaluate('document.documentElement.scrollWidth <= innerWidth')
  await page.screenshot(path=str(OUT/'03-dashboard-mobile.png'),full_page=True)
  await page.get_by_role('button',name='Let’s train').click()
  await page.get_by_role('button',name='Log Goblet squat set 1',exact=True).click()
  assert await page.get_by_role('button',name='Undo Goblet squat set 1',exact=True).count()==1
  await page.get_by_role('spinbutton',name='Goblet squat set 2 weight',exact=True).fill('20')
  await page.get_by_role('button',name='Log Goblet squat set 2',exact=True).click()
  await page.screenshot(path=str(OUT/'04-workout-mobile.png'),full_page=True)
  await page.wait_for_timeout(1800)
  await page.reload()
  await page.get_by_role('button',name='Resume workout').click()
  assert await page.get_by_role('button',name='Undo Goblet squat set 2',exact=True).count()==1
  await page.get_by_role('button',name='Finish workout').click()
  await page.get_by_role('heading',name='Ready for your next level, Ada?').wait_for()
  assert await page.get_by_text(re.compile(r'^\+\d+ XP$')).count()>=1
  await page.get_by_role('button',name='Claim reward',exact=True).click()
  assert await page.get_by_role('button',name='Claimed',exact=True).count()==1
  await page.set_viewport_size({'width':1440,'height':1000})
  await page.screenshot(path=str(OUT/'05-dashboard-desktop.png'),full_page=True)
  for label in ['Programs','Progress','Community','Mesocycle','Tools','Settings']:
   await page.get_by_role('button',name=label,exact=True).click()
   await page.wait_for_timeout(150)
   assert await page.evaluate('document.documentElement.scrollWidth <= innerWidth'), label
   await page.screenshot(path=str(OUT/(label.replace(' ','-').lower()+'.png')),full_page=True)
  await page.get_by_role('combobox',name='External load unit').select_option('lb')
  async with page.expect_download() as info:await page.get_by_role('button',name='Export backup',exact=True).click()
  download=await info.value;path=await download.path();backup=json.loads(Path(path).read_text());assert backup['players'][0]['unit']=='lb'
  await page.get_by_role('button',name='Tools',exact=True).click()
  await page.get_by_role('searchbox').fill('Romanian')
  assert await page.locator('#guides details').count()>0
  await page.get_by_role('button',name='Community',exact=True).click()
  await page.get_by_role('heading',name='Training Buddy',exact=True).wait_for()
  await page.get_by_role('button',name='Accept',exact=True).click()
  await page.get_by_role('button',name='Settings',exact=True).click()
  async with page.expect_file_chooser() as fc:await page.get_by_role('button',name='Import web backup',exact=True).click()
  chooser=await fc.value
  await chooser.set_files({'name':'backup.json','mimeType':'application/json','buffer':json.dumps(backup).encode()})
  await page.get_by_role('button',name='Confirm',exact=True).click()
  await page.get_by_role('heading',name='Ready for your next level, Ada?').wait_for()
  assert not errors,errors
  await browser.close()
  print('BROWSER PASS: Google/Apple sign-in options, onboarding, dashboard desktop/mobile, active workout reload, finish/XP, quest claim, all tabs, unit conversion, export/import, exercise search, party response; no JS errors or horizontal overflow.')
asyncio.run(main())
