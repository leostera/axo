// Rasterize Axo's committed Rive artboards, unchanged, for WPF and the Windows tray.
// Run after installing packages/axo-mascot's development dependencies. No network is used
// while rendering. Generated atlases are committed so normal builds need neither Chrome nor JS.
import fs from 'node:fs/promises';
import path from 'node:path';
import {createRequire} from 'node:module';
import {fileURLToPath} from 'node:url';
import {createServer} from 'node:http';
const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'../..');
const require=createRequire(path.join(root,'packages/axo-mascot/package.json'));
const {chromium}=require('playwright-core');
const runtime=path.dirname(require.resolve('@rive-app/canvas'));
const routes={'/rive.js':path.join(runtime,'rive.js'),'/rive.wasm':path.join(runtime,'rive.wasm'),'/axo.riv':path.join(root,'assets/mascot/axo.riv')};
const server=createServer(async(req,res)=>{
  if(req.url==='/'){res.setHeader('content-type','text/html');res.end('<html><body style="margin:0;background:transparent"><script src="/rive.js"></script></body></html>');return;}
  const file=routes[req.url];if(!file){res.writeHead(404).end();return;}
  res.setHeader('content-type',file.endsWith('.wasm')?'application/wasm':file.endsWith('.js')?'text/javascript':'application/octet-stream');res.end(await fs.readFile(file));
});
await new Promise(done=>server.listen(0,'127.0.0.1',done));
const browser=await chromium.launch({executablePath:process.env.CHROME_PATH??'C:/Program Files/Google/Chrome/Application/chrome.exe',headless:true});
try{
 const page=await browser.newPage();await page.goto(`http://127.0.0.1:${server.address().port}/`);
 const out=path.join(root,'windows/Axo/Assets');await fs.mkdir(out,{recursive:true});
 for(const [name,width,height,count,loading] of [['Mark',64,36,120,false],['Icon',128,128,120,false],['Face',256,146,120,false],['Loader',192,192,90,true],['Happy',192,192,30,false]]){
  const png=await page.evaluate(async({name,width,height,count,loading})=>{
   const {Rive,Layout,Fit,Alignment,RuntimeLoader}=window.rive;RuntimeLoader.setWasmUrl('/rive.wasm');
   const canvas=document.createElement('canvas');canvas.width=width;canvas.height=height;document.body.append(canvas);
   let mascot;await new Promise((resolve,reject)=>{mascot=new Rive({src:'/axo.riv',canvas,artboard:name==='Happy'?'Loader':name,stateMachines:'Mascot',autoplay:true,layout:new Layout({fit:Fit.Contain,alignment:Alignment.Center}),onLoad:resolve,onLoadError:reject});});
   const inputs=mascot.stateMachineInputs('Mascot');const input=n=>inputs.find(i=>i.name===n);
   input('loading').value=loading;
   if(name==='Happy')input('happy').fire();
   const atlas=document.createElement('canvas');atlas.width=width*12;atlas.height=height*Math.ceil(count/12);const ctx=atlas.getContext('2d');
   for(let i=0;i<count;i++){
    if(i===35)input('blink')?.fire();
    await new Promise(done=>setTimeout(()=>requestAnimationFrame(done),1000/30));
    ctx.drawImage(canvas,(i%12)*width,Math.floor(i/12)*height,width,height);
   }
   const data=atlas.toDataURL('image/png').split(',')[1];mascot.cleanup();canvas.remove();return data;
  },{name,width,height,count,loading});
  await fs.writeFile(path.join(out,`${name}.png`),Buffer.from(png,'base64'));console.log(`Rendered ${name}: ${count} original Rive frames`);
 }
 await fs.copyFile(path.join(root,'assets/macos/Assets.xcassets/AppIcon.appiconset/icon_256x256.png'),path.join(out,'AppIcon.png'));
 // Windows ICO container embeds the original PNG verbatim.
 const png=await fs.readFile(path.join(out,'AppIcon.png'));const ico=Buffer.alloc(22);ico.writeUInt16LE(1,2);ico.writeUInt16LE(1,4);ico.writeUInt16LE(1,10);ico.writeUInt16LE(32,12);ico.writeUInt32LE(png.length,14);ico.writeUInt32LE(22,18);
 await fs.writeFile(path.join(out,'Axo.ico'),Buffer.concat([ico,png]));
}finally{await browser.close();await new Promise(done=>server.close(done));}
