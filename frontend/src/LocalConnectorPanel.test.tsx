// @vitest-environment jsdom
import React from 'react';
import {render,screen} from '@testing-library/react';
import {expect,it} from 'vitest';
import {LocalConnectorPanel} from './LocalConnectorPanel';
it('offers a local download without file or password collection',()=>{
 const {container}=render(<LocalConnectorPanel/>);
 expect(screen.getByRole('link',{name:'Baixar conector local (.zip)'}).getAttribute('href')).toBe('/api/local-connector/download');
 expect(container.querySelector('input[type="file"]')).toBeNull();
 expect(container.querySelector('input[type="password"]')).toBeNull();
 expect(container.textContent).toContain('ainda não recebe a fila do site');
});
