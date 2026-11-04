// @vitest-environment jsdom
import React from 'react';
import {afterEach,it,expect,vi} from 'vitest';
import {render,screen,cleanup,fireEvent,waitFor} from '@testing-library/react';
import {UpdatePanel} from './UpdatePanel';
afterEach(cleanup);
it('explica instalação única no modo portátil',async()=>{render(<UpdatePanel api={vi.fn(async()=>({managed:false,version:'0.4.0',source:{},state:{phase:'idle'}}))}/>);expect(await screen.findByText('Instalar_no_PC.bat')).toBeTruthy();expect(screen.queryByRole('button',{name:'Verificar atualizações'})).toBeNull()});
it('expõe fonte pendente sem afirmar atualização online disponível',async()=>{render(<UpdatePanel api={vi.fn(async()=>({managed:true,configured:false,version:'0.4.0',source:{},state:{phase:'idle'}}))}/>);expect(await screen.findByText(/Falta configurar o endereço/)).toBeTruthy()});
it('exige salvar rascunhos antes de aplicar',async()=>{const api=vi.fn(async()=>({managed:true,configured:true,version:'0.4.0',source:{},state:{phase:'ready',version:'0.4.1'}}));render(<UpdatePanel api={api}/>);const btn=await screen.findByRole('button',{name:'Aplicar e reiniciar'});expect((btn as HTMLButtonElement).disabled).toBe(true);fireEvent.click(screen.getByRole('checkbox',{name:/Salvei os rascunhos/}));expect((btn as HTMLButtonElement).disabled).toBe(false);fireEvent.click(btn);await waitFor(()=>expect(api).toHaveBeenCalledWith('/updates/apply','POST',{confirm_saved:true}))});
