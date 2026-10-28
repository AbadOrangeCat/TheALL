// Read dimensions before handing compressed data to the native decoder.
export function imageDimensions(input) {
  const data=Buffer.from(input);
  if(data.length>=24&&data.subarray(0,8).equals(Buffer.from([137,80,78,71,13,10,26,10]))){
    if(data.toString('ascii',12,16)!=='IHDR')throw new Error('Invalid PNG header');
    return validate(data.readUInt32BE(16),data.readUInt32BE(20));
  }
  if(data.length<4||data[0]!==255||data[1]!==216)throw new Error('Choose a JPEG or PNG image');
  let offset=2;
  while(offset+3<data.length){
    if(data[offset++]!==255)throw new Error('Invalid JPEG marker');
    while(offset<data.length&&data[offset]===255)offset++;
    const marker=data[offset++];
    if(marker===217||marker===218)break;
    if(marker===1||(marker>=208&&marker<=215))continue;
    if(offset+2>data.length)break;
    const size=data.readUInt16BE(offset);
    if(size<2||offset+size>data.length)throw new Error('Invalid JPEG segment');
    if([192,193,194,195,197,198,199,201,202,203,205,206,207].includes(marker)){
      if(size<8)throw new Error('Invalid JPEG frame');
      return validate(data.readUInt16BE(offset+5),data.readUInt16BE(offset+3));
    }
    offset+=size;
  }
  throw new Error('The JPEG image has no frame dimensions');
}
function validate(width,height){if(!width||!height||width*height>16_000_000)throw new Error('The image exceeds 16 megapixels');return{width,height};}
