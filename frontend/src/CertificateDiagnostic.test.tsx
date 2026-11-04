// @vitest-environment jsdom
import React from 'react';
import {cleanup,fireEvent,render,screen,waitFor} from '@testing-library/react';
import {afterEach,expect,it,vi} from 'vitest';
import {CertificateDiagnostic} from './CertificateDiagnostic';
afterEach(cleanup);
it('requires explicit consent and clears the password after the diagnostic',async()=>{
 const api=vi.fn().mockResolvedValue({offline_ok:true,expires_on:'2027-01-01',chain_certificates:0,connection:{attempted:false,http_status:null,message:'Sem conexão externa.'},warnings:['Nenhuma DPS enviada.']});
 const {container}=render(<CertificateDiagnostic api={api}/>);
 const button=screen.getByRole('button',{name:'Verificar certificado'}) as HTMLButtonElement;
 expect(button.disabled).toBe(true);
 const password=screen.getByLabelText('Senha do arquivo A1') as HTMLInputElement;
 fireEvent.change(password,{target:{value:'SENHA-FICTICIA-TESTE'}});
 fireEvent.click(screen.getByLabelText(/Sou responsável/));
 fireEvent.submit(container.querySelector('form')!);
 await waitFor(()=>expect(api).toHaveBeenCalledTimes(1));
 expect(api.mock.calls[0][0]).toBe('/integrations/restricted/diagnostic');
 await screen.findByText(/Arquivo aberto e certificado dentro da validade/);
 expect(password.value).toBe('');expect(container.textContent).not.toContain('SENHA-FICTICIA-TESTE');
 expect((screen.getByLabelText(/Sou responsável/) as HTMLInputElement).checked).toBe(false);
});
it('does not send a certificate without consent',()=>{
 const api=vi.fn();const {container}=render(<CertificateDiagnostic api={api}/>);
 fireEvent.submit(container.querySelector('form')!);expect(api).not.toHaveBeenCalled();
});
