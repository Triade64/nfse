// Same CPF/CNPJ check digits as the backend (validation.valid_document), for immediate feedback while typing.
export const onlyDigits=(v:string)=>(v||'').replace(/\D/g,'');

export function validCpf(d:string):boolean{
 if(!/^\d{11}$/.test(d)||/^(\d)\1+$/.test(d))return false;
 for(const size of [9,10]){let sum=0;for(let i=0;i<size;i++)sum+=Number(d[i])*(size+1-i);if((sum*10)%11%10!==Number(d[size]))return false}
 return true;
}
export function validCnpj(d:string):boolean{
 if(!/^\d{14}$/.test(d)||/^(\d)\1+$/.test(d))return false;
 const check=(len:number)=>{const w=len===12?[5,4,3,2,9,8,7,6,5,4,3,2]:[6,5,4,3,2,9,8,7,6,5,4,3,2];const s=w.reduce((a,x,i)=>a+x*Number(d[i]),0)%11;return s<2?0:11-s};
 return check(12)===Number(d[12])&&check(13)===Number(d[13]);
}
export function formatDocument(v:string):string{
 const d=onlyDigits(v);
 if(d.length===11)return d.replace(/(\d{3})(\d{3})(\d{3})(\d{2})/,'$1.$2.$3-$4');
 if(d.length===14)return d.replace(/(\d{2})(\d{3})(\d{3})(\d{4})(\d{2})/,'$1.$2.$3/$4-$5');
 return v;
}
/** Plain-language status of a CPF/CNPJ being typed. */
export function documentStatus(v:string):{kind:'cpf'|'cnpj'|null;ok:boolean;message:string}{
 const d=onlyDigits(v);
 if(!d)return {kind:null,ok:false,message:''};
 if(/[A-Za-z]/.test(v))return {kind:null,ok:false,message:'Use somente números (CNPJ alfanumérico ainda não é aceito).'};
 if(d.length===11)return validCpf(d)?{kind:'cpf',ok:true,message:'Pessoa física (CPF) válido.'}:{kind:'cpf',ok:false,message:'CPF inválido: confira os dígitos.'};
 if(d.length===14)return validCnpj(d)?{kind:'cnpj',ok:true,message:'Pessoa jurídica (CNPJ) válido.'}:{kind:'cnpj',ok:false,message:'CNPJ inválido: confira os dígitos.'};
 return {kind:null,ok:false,message:`${d.length} dígitos: CPF tem 11 e CNPJ tem 14.`};
}
export const onlyCep=(v:string)=>onlyDigits(v).slice(0,8);
