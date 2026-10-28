export function externalWebURL(value) {
  try {const url=new URL(value);return ['https:','http:'].includes(url.protocol)&&!url.username&&!url.password;}catch{return false;}
}
export function validDesktopURL(value) {
  try {const url=new URL(value);return url.protocol==='http:'&&['127.0.0.1','[::1]','localhost'].includes(url.hostname)&&!url.username&&!url.password;}catch{return false;}
}
