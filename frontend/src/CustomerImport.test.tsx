// @vitest-environment jsdom
import React from 'react';
import {render,screen,fireEvent,waitFor,cleanup,within} from '@testing-library/react';
import {afterEach,expect,it,vi} from 'vitest';
import {CustomerImport} from './CustomerImport';
afterEach(()=>{cleanup();vi.restoreAllMocks()});
const row=(over={})=>({line:2,cnpj_emitente:'11222333000181',documento_tomador:'52998224725',nome_tomador:'CLIENTE A',action:'Novo',errors:[],warnings:[],...over});
const file=new File(['x'],'tomadores.xlsx');

function pick(container:HTMLElement){fireEvent.change(container.querySelector('input[type="file"]')!,{target:{files:[file]}})}

it('previews first and imports the same file only after confirmation',async()=>{
 const preview={sha256:'a'.repeat(64),summary:{total:2,novos:1,atualizar:1,erros:0,avisos:1},rows:[row(),row({line:3,action:'Atualizar',nome_tomador:'CLIENTE B',warnings:['Nome atual "B" será substituído.']})]};
 const api=vi.fn().mockResolvedValueOnce(preview).mockResolvedValueOnce({created:1,updated:1});
 const done=vi.fn();
 const {container}=render(<CustomerImport api={api} onImported={done}/>);
 expect(screen.getByRole('link',{name:/Modelo de tomadores/}).getAttribute('href')).toBe('/api/customers/template.xlsx');
 pick(container);
 const dialog=await screen.findByRole('dialog');
 expect(dialog.textContent).toContain('Nada foi gravado ainda');expect(dialog.textContent).toContain('será substituído');
 expect(api.mock.calls[0][0]).toBe('/customers/import');
 fireEvent.click(within(dialog).getByRole('button',{name:'Importar 2 tomadores'}));
 await waitFor(()=>expect(done).toHaveBeenCalledWith('Importação concluída: 1 novo e 1 atualizado.'));
 expect(api.mock.calls[1][0]).toBe('/customers/import?confirm=true&expected_sha256='+'a'.repeat(64));
 expect(screen.queryByRole('dialog')).toBeNull();
});

it('blocks the import while any line has an error',async()=>{
 const api=vi.fn().mockResolvedValueOnce({sha256:'b'.repeat(64),summary:{total:1,novos:0,atualizar:0,erros:1,avisos:0},rows:[row({action:'Com erro',errors:['CPF/CNPJ do tomador inválido.']})]});
 const {container}=render(<CustomerImport api={api} onImported={vi.fn()}/>);
 pick(container);
 const dialog=await screen.findByRole('dialog');
 expect(dialog.textContent).toContain('CPF/CNPJ do tomador inválido.');
 expect((within(dialog).getByRole('button',{name:/Importar 1 tomador/}) as HTMLButtonElement).disabled).toBe(true);
});

it('shows a file refusal without opening the preview',async()=>{
 const api=vi.fn().mockRejectedValueOnce(new Error('Cabeçalhos incompatíveis. Baixe o modelo de tomadores no site e preserve todas as colunas.'));
 const {container}=render(<CustomerImport api={api} onImported={vi.fn()}/>);
 pick(container);
 expect((await screen.findByRole('alert')).textContent).toContain('Cabeçalhos incompatíveis');
 expect(screen.queryByRole('dialog')).toBeNull();
});
