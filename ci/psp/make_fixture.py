# SPDX-License-Identifier: AGPL-3.0-only
"""Original PSP ELF smoke fixture. No console SDK or game assets."""
from pathlib import Path
import argparse
import struct
def fixture():
 BASE=0x08804000
 words=[];labels={};fixups=[]
 def emit(w): words.append(w)
 def li(r,v): emit(0x3c000000|r<<16|((v>>16)&65535));emit(0x34000000|r<<21|r<<16|(v&65535))
 def addi(rt,rs,n):emit(0x24000000|rs<<21|rt<<16|(n&65535))
 def sw(rt,rs,n):emit(0xac000000|rs<<21|rt<<16|(n&65535))
 def lw(rt,rs,n):emit(0x8c000000|rs<<21|rt<<16|(n&65535))
 def andi(rt,rs,n):emit(0x30000000|rs<<21|rt<<16|n)
 def move(rd,rs):emit(rs<<21|rd<<11|0x21)
 def label(n):labels[n]=len(words)
 def branch(op,rs,rt,n):fixups.append((len(words),n));emit(op<<26|rs<<21|rt<<16);emit(0)
 def call(addr):emit(0x0c000000|((addr>>2)&0x03ffffff));emit(0)
 def jump(n): fixups.append((len(words),n,'jump'));emit(0x08000000);emit(0)
 stubs={}
 imports=[('sceDisplay',[0x0E20F177,0x289D82FE,0x984C27E7]),('sceCtrl',[0x1F4011E6,0x3A622550]),('sceAudio',[0x5EC81C55,0x136CAF51])]
 i=0
 for name,nids in imports:
  for nid in nids:stubs[nid]=BASE+0x900+i*8;i+=1
 li(16,BASE+0xc00);li(8,0x49525431);sw(8,16,0);addi(8,0,7);addi(9,0,3);emit(8<<21|9<<16|10<<11|0x21);sw(10,16,4)
 # Original two-color frame, physical stride 512.
 li(8,0x04000000)
 for name,color in [('red',0xff0000ff),('blue',0xffff0000)]:
  li(9,512*136);li(10,color);label(name);sw(10,8,0);addi(8,8,4);addi(9,9,-1);branch(5,9,0,name)
 li(4,0);li(5,480);li(6,272);call(stubs[0x0E20F177]);sw(2,16,0x20)
 li(4,0x04000000);li(5,512);li(6,3);li(7,1);call(stubs[0x289D82FE]);sw(2,16,0x24)
 li(4,1);call(stubs[0x1F4011E6])
 # Original 344 Hz square wave; opposite stereo channels.
 li(8,BASE+0x1000);li(9,1024);li(10,0xf0001000);li(11,0xe000e000);label('pcm');sw(10,8,0);addi(8,8,4);addi(9,9,-1);andi(12,9,63);branch(5,12,0,'same_sign');emit(10<<21|11<<16|10<<11|0x26);label('same_sign');branch(5,9,0,'pcm')
 li(4,0xffffffff);li(5,1024);li(6,0);call(stubs[0x5EC81C55]);move(19,2);sw(2,16,8);li(20,0)
 label('loop');call(stubs[0x984C27E7]);li(4,BASE+0xc40);li(5,1);call(stubs[0x3A622550]);sw(2,16,0x28)
 li(8,BASE+0xc40);lw(9,8,4);sw(9,16,0x10);lw(10,8,8);sw(10,16,0x14);andi(9,9,0x4000)
 li(10,0xff0000ff);branch(4,9,0,'released');li(10,0xff00ff00);label('released');li(8,0x0400c060);sw(10,8,0)
 addi(20,20,1);sw(20,16,0xc);move(4,19);li(5,0x8000);li(6,BASE+0x1000);call(stubs[0x136CAF51]);sw(2,16,0x2c);jump('loop')
 for f in fixups:
  idx,name,*kind=f
  if kind: words[idx]|=((BASE+labels[name]*4)>>2)&0x3ffffff
  else:words[idx]|=(labels[name]-idx-1)&65535
 assert len(words)*4 < 0x800
 segment=bytearray(0x2000);segment[:len(words)*4]=struct.pack('<'+'I'*len(words),*words)
 segment[0x800:0x834]=struct.pack('<HH28sIIIII',0,0x0100,b'Iridium original fixture',0,BASE+0xb00,BASE+0xb00,BASE+0xa00,BASE+0xa00+20*len(imports))
 nameoffset=0x840;nidoffset=0xa60;stuboffset=0x900
 for idx,(name,nids) in enumerate(imports):
  encoded=name.encode()+b'\0';segment[nameoffset:nameoffset+len(encoded)]=encoded
  segment[0xa00+idx*20:0xa00+(idx+1)*20]=struct.pack('<IHHBBHII',BASE+nameoffset,0x0100,0,5,0,len(nids),BASE+nidoffset,BASE+stuboffset)
  for nid in nids:
   struct.pack_into('<I',segment,nidoffset,nid);nidoffset+=4
   struct.pack_into('<II',segment,stuboffset,0x03e00008,0);stuboffset+=8
  nameoffset+=len(encoded)
 ident=b'\x7fELF\x01\x01\x01'+bytes(9)
 header=struct.pack('<16sHHIIIIIHHHHHH',ident,2,8,1,BASE,52,0,0x10001001,52,32,1,40,0,0)
 ph=struct.pack('<IIIIIIII',1,0x1000,BASE,0x1800,len(segment),0x3000,7,0x1000)
 return header+ph+bytes(0x1000-len(header)-len(ph))+segment


if __name__ == "__main__":
 parser = argparse.ArgumentParser(description=__doc__)
 parser.add_argument("output", type=Path)
 args = parser.parse_args()
 args.output.write_bytes(fixture())
