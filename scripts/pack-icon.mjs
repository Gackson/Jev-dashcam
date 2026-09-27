import { readFileSync, writeFileSync } from 'node:fs';
const chunks = [
  ['icp4', '16x16'], ['icp5', '32x32'], ['icp6', '32x32@2x'],
  ['ic07', '128x128'], ['ic08', '256x256'], ['ic09', '512x512'], ['ic10', '512x512@2x'],
].map(([type, size]) => {
  const png = readFileSync(`build/AppIcon.iconset/icon_${size}.png`);
  const header = Buffer.alloc(8); header.write(type); header.writeUInt32BE(png.length + 8, 4);
  return Buffer.concat([header, png]);
});
const header = Buffer.alloc(8); header.write('icns'); header.writeUInt32BE(8 + chunks.reduce((sum, chunk) => sum + chunk.length, 0), 4);
writeFileSync(process.argv[2], Buffer.concat([header, ...chunks]));
