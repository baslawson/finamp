// Run with Playwright installed: NODE_PATH=<modules> node test_hub_browser.cjs
// HUB_TEST_CAPS is a private, temporary JSON file issued by the test setup.
const { chromium } = require('playwright');
const fs = require('node:fs');
const assert = require('node:assert/strict');
const path = require('node:path');

(async () => {
  const base = process.env.HUB_TEST_URL;
  const caps = JSON.parse(fs.readFileSync(process.env.HUB_TEST_CAPS, 'utf8'));
  const browser = await chromium.launch({headless:true, channel:process.env.HUB_TEST_BROWSER || 'msedge'});
  const context = await browser.newContext({viewport:{width:1366,height:900}});
  const errors=[];
  context.on('page', page => page.on('pageerror', error => errors.push(error.name)));
  const admin = await context.newPage();
  await admin.goto(base+'/admin/#'+caps.admin);
  await admin.getByRole('heading',{name:'Your music, around the house'}).waitFor();
  for(const [name,heading] of [['Radio','A station that stays on'],['TV karaoke','Put karaoke on a bigger screen'],['Overnight','Ready before the party'],['Lyrics','Lyrics, ready when you press play'],['Audio health','Catch problem recordings'],['Across devices','Pick up on another device'],['Backups','A restore point for your server']]) {
    await admin.getByRole('button',{name,exact:true}).click();
    await admin.getByRole('heading',{name:heading,exact:true}).waitFor();
  }
  assert.equal(new URL(admin.url()).hash,'','Capability removed from browser address');
  await admin.screenshot({path:path.join(process.env.HUB_TEST_OUTPUT,'hub-desktop.png'),fullPage:true});
  await admin.setViewportSize({width:390,height:844});
  assert.equal(await admin.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),true,'Dashboard fits a phone');
  await admin.screenshot({path:path.join(process.env.HUB_TEST_OUTPUT,'hub-phone.png'),fullPage:true});

  const tv = await context.newPage();
  await tv.goto(base+'/tv/');
  await tv.getByLabel('Pairing code').fill(caps.room.code);
  await tv.getByRole('button',{name:'Connect TV',exact:true}).click();
  await tv.getByRole('button',{name:'Start TV audio',exact:true}).waitFor();
  const remote = await context.newPage();
  await remote.goto(base+'/remote/#'+caps.room.control);
  await remote.getByRole('heading',{name:'Your karaoke remote'}).waitFor();
  const song = process.env.HUB_TEST_SONG;
  const command=async(action,values={})=>remote.evaluate(async({action,values})=>{
    const state=await api('/api/room/state');
    return api('/api/room/command','POST',{action,revision:state.commandRev,...values});
  },{action,values});
  await command('select',{song});
  await tv.waitForFunction(()=>roomState?.mediaReady===true,{},{timeout:120000});
  if(process.env.HUB_TEST_TIMED_LYRICS==='true') {
    await tv.waitForFunction(()=>lyrics.length>0,{},{timeout:90000});
  }
  await tv.getByRole('button',{name:'Start TV audio',exact:true}).click();
  await tv.waitForFunction(()=>document.querySelector('audio').currentTime>1,{},{timeout:30000});
  await command('pause');
  await tv.waitForFunction(()=>document.querySelector('audio').paused);
  await command('seek',{positionMs:12000});
  await tv.waitForFunction(()=>Math.abs(document.querySelector('audio').currentTime-12)<1);
  await command('guide',{guide:25});
  await tv.waitForFunction(()=>roomState?.mediaReady===true&&roomState.guide===25,{},{timeout:120000});
  await command('play');
  await tv.waitForFunction(()=>!document.querySelector('audio').paused);
  await tv.screenshot({path:path.join(process.env.HUB_TEST_OUTPUT,'hub-tv.png'),fullPage:true});
  const guest = await context.newPage();
  await guest.goto(base+'/guest/#'+caps.room.guest);
  await guest.getByRole('heading',{name:'Choose the next song'}).waitFor();
  const second=process.env.HUB_TEST_SECOND;
  await guest.evaluate(async song=>api('/api/room/request','POST',{song,guest:'Browser QA'}),second);
  await remote.getByText('Requested by Browser QA',{exact:true}).waitFor();
  await command('next');
  await tv.waitForFunction(id=>roomState?.song?.id===id,second);
  assert.equal(errors.length,0,'No browser runtime errors');
  await browser.close();
  console.log('PASS: dashboard tabs, desktop/phone layout, TV pairing, real audio, pause, seek, guide vocals, guest request, next song; no browser errors.');
})().catch(error=>{
  // Avoid echoing private capabilities in Playwright URL diagnostics.
  console.error('Browser regression failed:',error.name, String(error.message).replace(/#[^\s'\"]+/g,'#[private-link]').slice(0,500));
  process.exit(1);
});
