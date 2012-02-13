function [x]=dmrg_solve3(A, y, tol, varargin)
%Solution of linear systems in TT-format via DMRG iteration
%   [X,SWEEPS]=DMRG_SOLVE3(A,Y,TOL,OPTIONS) Attempts to solve the linear
%   system A*X = Y with accuracy/residual TOL using the two-sided DMRG iteration.
%   Matrix A has to be given in the TT-format, right-hand side Y should be
%   given in the TT-format also. Options are provided in form
%   'PropertyName1',PropertyValue1,'PropertyName2',PropertyValue2 and so
%   on. The parameters are set to default (in brackets in the following) 
%   The list of option names and default values are:
%       o x0 - initial approximation [random rank-2 tensor] 
%       o P - preconditioner  [I]
%       o nswp - maximal number of DMRG sweeps [10]
%       o rmax - maximal TT-rank of the solution [1000]
%       o verb - verbosity level, 0-silent, 1-sweep info, 2-block info [1]
%       o max_full_size - maximal size of the local matrix to full solver 
%       [2500]
%       o local_prec: Local preconditioner, 'als' - ALS-Richardson
%       iteration, 'selfprec' (Saad selfpreconditioner) ['als']
%       o prec_compr - compression for local precs [1e-3]
%       o prec_tol - tolerance for local precs [1e-1]
%       o prec_iters - number of local iterations [15]
%       o use_self_prec - Use self_prec [ true | {false} ]
%       o gmres_iters - number of local gmres restarts [2]
%       o nrestart - dimension of local gmres [40]
%       Example:
%           d=8; f=8; 
%           mat=tt_qlaplace_dd(d*ones(1,f)); %Laplace in the QTT-format
%           rhs=tt_ones(2,d*f); Right-hand side of all ones
%           sol=dmrg_solve3(mat,rhs,1e-6);
%
%
% TT-Toolbox 2.2, 2009-2012
%
%This is TT Toolbox, written by Ivan Oseledets et al.
%Institute of Numerical Mathematics, Moscow, Russia
%webpage: http://spring.inm.ras.ru/osel
%
%For all questions, bugs and suggestions please mail
%ivan.oseledets@gmail.com
%---------------------------


% Inner parameters
max_full_size=2500;
step_dpow = 0.1; % stepsize for d-power in truncations
min_dpow = 1; % Minimal d-power for truncation

resid_damp = 1.5; % Truncation error to true residual treshold
bot_conv = 0.1; % bottom convergence factor - if better, we can decrease dpow and drank
top_conv = 0.99; % top convergence factor - if worse, we have to increase dpow and drank


nswp=10;
local_restart=40;
local_iters=2;

local_prec = '';
% local_prec = 'jacobi';

rmax=1000;
trunc_norm = 'residual';
% trunc_norm = 'fro';

local_solver = 'gmres';
% local_solver = 'pcg';

verb=1;
kickrank = 2;
x=[];

for i=1:2:length(varargin)-1
    switch lower(varargin{i})
        case 'nswp'
            nswp=varargin{i+1};
        case 'rmax'
            rmax=lower(varargin{i+1});
        case 'x0'
            x=varargin{i+1};
        case 'verb'
            verb=varargin{i+1};
        case 'local_prec'
            local_prec=varargin{i+1};
        case 'local_restart'
            local_restart=varargin{i+1};
        case 'local_iters'
            local_iters=varargin{i+1};
        case 'local_solver'
            local_solver=varargin{i+1};            
        case 'kickrank'
            kickrank=varargin{i+1};
        case  'max_full_size'
            max_full_size=varargin{i+1};
        case 'step_dpow'
            step_dpow=varargin{i+1};
        case 'min_dpow'
            min_dpow=varargin{i+1};
        case 'resid_damp'
            resid_damp = varargin{i+1};
        case 'trunc_norm'
            trunc_norm = varargin{i+1};
        case 'bot_conv'
            bot_conv=varargin{i+1};
        case 'top_conv'
            top_conv=varargin{i+1};
            
        otherwise
            error('Unrecognized option: %s\n',varargin{i});
    end
end


if (A.n~=A.m)
    error(' DMRG does not know how to solve rectangular systems!\n Use dmrg_solve3(ctranspose(A)*A, ctranspose(A)*f, tol) instead.');
end;

d = y.d;
n = A.n;
if (isempty(x))
    x = tt_rand(n, A.d, kickrank);
end;

ry = y.r;
ra = A.r;
rx = x.r;

phia = cell(d+1,1); phia{1}=1; phia{d+1}=1;
phiy = cell(d+1,1); phiy{1}=1; phiy{d+1}=1;

% This is for checking the residual via averaging
cphia = cell(d+1,1); cphia{1}=1; cphia{d+1}=1;
cphiy = cell(d+1,1); cphiy{1}=1; cphiy{d+1}=1;


% Orthogonalization
for i=d:-1:2
    cr = x{i};
    cr = reshape(cr, rx(i), n(i)*rx(i+1));
    [cr, rv]=qr(cr.', 0);
    cr2 = x{i-1};
    cr2 = reshape(cr2, rx(i-1)*n(i-1), rx(i));
    cr2 = cr2*(rv.');
    rx(i) = size(cr, 2);
    cr = reshape(cr.', rx(i), n(i), rx(i+1));
    x{i-1} = reshape(cr2, rx(i-1), n(i-1), rx(i));
    x{i} = cr;
    
    phia{i} = compute_next_Phi(phia{i+1}, cr, A{i}, cr, 'rl');
    phiy{i} = compute_next_Phi(phiy{i+1}, cr, [], y{i}, 'rl');
    
    % For residual-check
    cphia{i} = compute_next_Phi(cphia{i+1}, ones(1, n(i)), A{i}, cr, 'rl');
    cphiy{i} = compute_next_Phi(cphiy{i+1}, ones(1, n(i)), [], y{i}, 'rl');
end;


dir = 1; % l-to-r
last_sweep = false;
swp = 1;
i = 1;

dx_old = ones(d,1);
dx = zeros(d,1);
max_res = 0;
max_dx = 0;
% For extra-rank addition
dpows = ones(d,1)*min_dpow;
dranks = zeros(d,1);

% DMRG sweeps
while (swp<=nswp)
    % Extract elements - matrix
    Phi1 = phia{i}; Phi2 = phia{i+2};
    A1 = A{i}; A2 = A{i+1};
    % RHS
    rhs = phiy{i};
    rhs = rhs*reshape(y{i}, ry(i), n(i)*ry(i+1));
    rhs = reshape(rhs, rx(i)*n(i), ry(i+1));
    rhs = rhs*reshape(y{i+1}, ry(i+1), n(i+1)*ry(i+2));
    rhs = reshape(rhs, rx(i)*n(i)*n(i+1), ry(i+2));
    rhs = rhs*(phiy{i+2}.');
    rhs = reshape(rhs, rx(i)*n(i)*n(i+1)*rx(i+2),1);
    norm_rhs = norm(rhs);
    % sol_prev
    sol_prev = reshape(x{i}, rx(i)*n(i), rx(i+1));
    sol_prev = sol_prev*reshape(x{i+1}, rx(i+1), n(i+1)*rx(i+2));
    sol_prev = reshape(sol_prev, rx(i)*n(i)*n(i+1)*rx(i+2),1);
    
    real_tol = (tol/(d^dpows(i)))/resid_damp;
    if (last_sweep)
        real_tol = tol/sqrt(d)/resid_damp;
    end;
    
    if (rx(i)*n(i)*n(i+1)*rx(i+2)<max_full_size) % Full solution
        %      |     |    |     |
        % B = Phi1 - A1 - A2 - Phi2
        %      |     |    |     |
        B = reshape(permute(Phi1, [1, 3, 2]), rx(i)*rx(i), ra(i));
        B = B*reshape(A1, ra(i), n(i)*n(i)*ra(i+1));
        B = reshape(B, rx(i), rx(i), n(i), n(i), ra(i+1));
        B = permute(B, [1, 3, 2, 4, 5]);
        B = reshape(B, rx(i)*n(i)*rx(i)*n(i), ra(i+1));
        B = B*reshape(A2, ra(i+1), n(i+1)*n(i+1)*ra(i+2));
        B = reshape(B, rx(i)*n(i), rx(i)*n(i), n(i+1), n(i+1), ra(i+2));
        B = permute(B, [1, 3, 2, 4, 5]);
        B = reshape(B, rx(i)*n(i)*n(i+1)*rx(i)*n(i)*n(i+1), ra(i+2));
        B = B*reshape(permute(Phi2, [2, 1, 3]), ra(i+2), rx(i+2)*rx(i+2));
        B = reshape(B, rx(i)*n(i)*n(i+1), rx(i)*n(i)*n(i+1), rx(i+2), rx(i+2));
        B = permute(B, [1, 3, 2, 4]);
        B = reshape(B, rx(i)*n(i)*n(i+1)*rx(i+2), rx(i)*n(i)*n(i+1)*rx(i+2));
        
        res_prev = norm(B*sol_prev-rhs)/norm_rhs;
        sol = B \ rhs;
        flg = 0;
        % If the system was ill-conditioned
%         [sol,flg] = gmres(B, rhs, local_restart, real_tol, 2, [], [], sol);
        res_new = norm(B*sol-rhs)/norm_rhs;
        
    else % Structured solution.
        
        res_prev = norm(bfun3(Phi1, A1, A2, Phi2, sol_prev) - rhs)/norm_rhs;
        
        if (strcmp(local_prec, 'jacobi'))&&(~last_sweep)
            % Prepare the Jacobi prec - on maximal rank
            if (rx(i)>rx(i+2))
                jacPhi1 = reshape(permute(Phi1, [1, 3, 2]), rx(i)*rx(i), ra(i));
                ind = (1:rx(i)) + (0:rx(i)-1)*rx(i); % diagonal elements
                jacPhi = jacPhi1(ind,:);
                % The second block, unfortunately, to compute explicitly
                jacB = reshape(A1, ra(i)*n(i)*n(i), ra(i+1));
                jacB = jacB*reshape(A2, ra(i+1), n(i+1)*n(i+1)*ra(i+2));
                jacB = reshape(jacB, ra(i), n(i), n(i), n(i+1), n(i+1), ra(i+2));
                jacB = permute(jacB, [1, 2, 4, 3, 5, 6]);
                jacB = reshape(jacB, ra(i)*n(i)*n(i+1)*n(i)*n(i+1), ra(i+2));
                jacB = jacB*reshape(permute(Phi2, [2, 1, 3]), ra(i+2), rx(i+2)*rx(i+2));
                jacB = reshape(jacB, ra(i), n(i)*n(i+1), n(i)*n(i+1), rx(i+2), rx(i+2));
                jacB = permute(jacB, [2, 4, 3, 5, 1]);
                jacB = reshape(jacB, n(i)*n(i+1)*rx(i+2), n(i)*n(i+1)*rx(i+2), ra(i));

                jacBlocks = cell(rx(i),1);
                for k=1:rx(i)
                    jacBlocks{k}=zeros(n(i)*n(i+1)*rx(i+2), n(i)*n(i+1)*rx(i+2));
                end;
                % So stupid preallocation of sparsity
                jacP = 0*speye(rx(i)*n(i)*n(i+1)*rx(i+2));
                % Sum over ra                
                for k=1:ra(i)                    
                    for m=1:rx(i)
                        jacBlocks{m} = jacBlocks{m} + jacB(:,:,k)*jacPhi(m,k);
                    end;
                end;
                % Stuff into the prec
                for m=1:rx(i)
                    em = [zeros(m-1,1); 1; zeros(rx(i)-m, 1)];
                    jacBlocks{m} = inv(jacBlocks{m});
                    jacP = jacP + kron(jacBlocks{m}, spdiags(em, 0, rx(i), rx(i)));
                end;
                
            else
                
                jacPhi2 = reshape(permute(Phi2, [2, 1, 3]), ra(i+2), rx(i+2)*rx(i+2));
                ind = (1:rx(i+2)) + (0:rx(i+2)-1)*rx(i+2); % diagonal elements
                jacPhi = jacPhi2(:,ind);
                % The second block, unfortunately, to compute explicitly
                jacB = reshape(permute(Phi1, [1, 3, 2]), rx(i)*rx(i), ra(i));
                jacB = jacB*reshape(A1, ra(i), n(i)*n(i)*ra(i+1));
                jacB = reshape(jacB, rx(i), rx(i), n(i), n(i), ra(i+1));
                jacB = permute(jacB, [1, 3, 2, 4, 5]);
                jacB = reshape(jacB, rx(i)*n(i)*rx(i)*n(i), ra(i+1));
                jacB = jacB*reshape(A2, ra(i+1), n(i+1)*n(i+1)*ra(i+2));
                jacB = reshape(jacB, rx(i)*n(i), rx(i)*n(i), n(i+1), n(i+1), ra(i+2));
                jacB = permute(jacB, [1, 3, 2, 4, 5]);
                jacB = reshape(jacB, rx(i)*n(i)*n(i+1), rx(i)*n(i)*n(i+1), ra(i+2));

                jacBlocks = cell(rx(i+2),1);
                for k=1:rx(i+2)
                    jacBlocks{k}=zeros(rx(i)*n(i)*n(i+1), rx(i)*n(i)*n(i+1));
                end;
                % So stupid preallocation of sparsity
                jacP = 0*speye(rx(i)*n(i)*n(i+1)*rx(i+2));
                % Sum over ra                
                for k=1:ra(i+2)                    
                    for m=1:rx(i+2)
                        jacBlocks{m} = jacBlocks{m} + jacB(:,:,k)*jacPhi(k,m);
                    end;
                end;
                % Stuff into the prec
                for m=1:rx(i+2)
                    em = [zeros(m-1,1); 1; zeros(rx(i+2)-m, 1)];
                    jacBlocks{m} = inv(jacBlocks{m});
                    jacP = jacP + kron(spdiags(em, 0, rx(i+2), rx(i+2)), jacBlocks{m});
                end;                
            end;
        else
            jacP = [];
        end;
        
        % Run the iterative solution
        if (strcmp(local_solver, 'gmres'))
            if (isempty(jacP))
                [sol,flg] = gmres(@(v)bfun3(Phi1, A1, A2, Phi2, v), rhs, local_restart, real_tol, ...
                    local_iters, [], [], sol_prev);
            else
                [sol,flg] = gmres(@(v)bfun3(Phi1, A1, A2, Phi2, v), rhs, local_restart, real_tol, ...
                    local_iters, @(v)(jacP*v), [], sol_prev);
            end;
        else
            if (isempty(jacP))
                [sol,flg] = pcg(@(v)bfun3(Phi1, A1, A2, Phi2, v), rhs, real_tol, ...
                    local_iters*local_restart, [], [], sol_prev);
            else
                [sol,flg] = pcg(@(v)bfun3(Phi1, A1, A2, Phi2, v), rhs, real_tol, ...
                    local_iters*local_restart, @(v)(jacP*v), [], sol_prev);
            end;
        end;
        
        res_new = norm(bfun3(Phi1, A1, A2, Phi2, sol) - rhs)/norm_rhs;        
    end;
    
    if (flg>0)
        fprintf('-warn- local solver did not converge at block %d\n', i);
    end;
    if (res_prev/res_new<resid_damp)&&(res_new>real_tol)
        fprintf('--warn-- the residual damp was smaller than in the truncation\n');
    end;
    
    dx(i) = norm(sol-sol_prev)/norm(sol);
    max_dx = max(max_dx, dx(i));
    
    % The new core does not converge - increase rank
    if (dx(i)/dx_old(i)>top_conv)&&(dx(i)>tol)
        dranks(i)=dranks(i)+1;
        dpows(i)=dpows(i)+step_dpow;
    end;
    % The new core converges well - try to decrease rank
    if (dx(i)/dx_old(i)<bot_conv)||(dx(i)<tol)
        dranks(i)=max(dranks(i)-1, 0);
        dpows(i)=max(dpows(i)-step_dpow, min_dpow);
    end;
    
    if (last_sweep)
        dpows(i)=0.5;
        dranks(i)=0;
    end;
    
    % Check the residual
    cPhi1 = cphia{i}; cPhi2 = cphia{i+2};
    crhs = cphiy{i};
    crhs = crhs*reshape(y{i}, ry(i), n(i)*ry(i+1));
    crhs = reshape(crhs, n(i), ry(i+1));
    crhs = crhs*reshape(y{i+1}, ry(i+1), n(i+1)*ry(i+2));
    crhs = reshape(crhs, n(i)*n(i+1), ry(i+2));
    crhs = crhs*(cphiy{i+2}.');
    cAsol = bfun3(cPhi1, A1, A2, cPhi2, sol);
    res = norm(cAsol-crhs)/norm(crhs);
    
    
    max_res = max(max_res, res);
%     max_res = max(max_res, res_prev);
    
    % Truncation
    sol = reshape(sol, rx(i)*n(i), n(i+1)*rx(i+2));
    [u,s,v]=svd(sol, 'econ');
    s = diag(s);
    
    if (strcmp(trunc_norm, 'fro')) % We are happy with L2 truncation (when? but let it be)
        r = my_chop2(s, max(tol/(d^dpows(i)), res_new*resid_damp)*norm(s));        
    else
        % Residual trunc; First, bin-search
        r1 = 1; r2 = numel(s); r = round((r1+r2)/2);
        while (r2-r1>1)
            cursol = u(:,1:r)*diag(s(1:r))*(v(:,1:r)');
            if (rx(i)*n(i)*n(i+1)*rx(i+2)<max_full_size)
                res = norm(B*cursol(:)-rhs)/norm_rhs;
            else
                res = norm(bfun3(Phi1, A1, A2, Phi2, cursol)-rhs)/norm_rhs;
            end;
            if (res<max(tol/(d^dpows(i)), res_new*resid_damp))
                r2 = r;
            else
                r1 = r;
            end;
            r = round((r1+r2)/2);
        end;
        % More accurate Linear search
        while (r<=numel(s))
            cursol = u(:,1:r)*diag(s(1:r))*(v(:,1:r)');
            if (rx(i)*n(i)*n(i+1)*rx(i+2)<max_full_size)
                res = norm(B*cursol(:)-rhs)/norm_rhs;
            else
                res = norm(bfun3(Phi1, A1, A2, Phi2, cursol)-rhs)/norm_rhs;
            end;
            if (res<max(tol/(d^dpows(i)), res_new*resid_damp))
                break;
            end;
            r = r+1;
        end;
    end;
    
    % Artificial rank increasing
    r = r+dranks(i);
    r = min(r, numel(s));
    r = min(r, rmax);
    
    if (verb>1)
        fprintf('=dmrg_solve3=   block %d{%d}, dx: %3.3e, res: %3.3e, r: %d\n', i, dir, dx(i), res, r);
    end;
    
    if (dir==1) % left-to-right
        u = u(:,1:r);
        v = v(:,1:r)*diag(s(1:r));
        % kick
        if (~last_sweep)
            u = reort(u, randn(rx(i)*n(i), kickrank));
        end;
        radd = size(u, 2)-r;
        v = [v, zeros(n(i+1)*rx(i+2), radd)];
        
        r = r+radd;
        
        u = reshape(u, rx(i), n(i), r);
        v = reshape(v', r, n(i+1), rx(i+2));
        
        % Recompute phi. Left ones, so permute them appropriately
        phia{i+1} = compute_next_Phi(phia{i}, u, A{i}, u, 'lr');
        phiy{i+1} = compute_next_Phi(phiy{i}, u, [], y{i}, 'lr');
        
        % residual-check
        cphia{i+1} = compute_next_Phi(cphia{i}, ones(1,n(i)), A{i}, u, 'lr');
        cphiy{i+1} = compute_next_Phi(cphiy{i}, ones(1,n(i)), [], y{i}, 'lr');
        
    else % right-to-left
        u = u(:,1:r)*diag(s(1:r));
        v = v(:,1:r);
        % kick
        if (~last_sweep)
            v = reort(v, randn(n(i+1)*rx(i+2), kickrank));
        end;
        radd = size(v, 2)-r;
        u = [u, zeros(rx(i)*n(i), radd)];
        
        r = r+radd;
        
        u = reshape(u, rx(i), n(i), r);
        v = reshape(v', r, n(i+1), rx(i+2));
        
        % Recompute phi. Here are right phis
        phia{i+1} = compute_next_Phi(phia{i+2}, v, A{i+1}, v, 'rl');
        phiy{i+1} = compute_next_Phi(phiy{i+2}, v, [], y{i+1}, 'rl');        
        % Residual check
        cphia{i+1} = compute_next_Phi(cphia{i+2}, ones(1,n(i+1)), A{i+1}, v, 'rl');
        cphiy{i+1} = compute_next_Phi(cphiy{i+2}, ones(1,n(i+1)), [], y{i+1}, 'rl');        
    end;
    
    % Stuff back
    rx(i+1) = r;
    x{i} = u;
    x{i+1} = v;
    
    i = i+dir;
    
    % Reversing, residue check, etc
    if ((i==d)&&(dir==1))||((i==0)&&(dir==-1))
        dir=-dir; % go back
        
        if (last_sweep)
            break;
        end;
        
        %residue
        if (strcmp(trunc_norm, 'fro'))
            if (max_dx<tol)
                last_sweep=true;
            end;
        else
            if (max_res<tol)
                last_sweep=true;
            end;
        end;
        
        if (verb>0)
            fprintf('=dmrg_solve3= sweep %d{%d}, max_dx: %3.3e, max_res: %3.3e, erank: %g\n', swp, -dir, max_dx, max_res, erank(x));
        end;
        
%         global_res = norm(A*x-y)/norm(y)
        
        max_res = 0;
        max_dx = 0;
        dx_old = dx;
        
        if (i==0)&&(dir==1)
            swp = swp+1;
        end;
        
        i = i+dir;
    end;        
end;


end


function [Phi] = compute_next_Phi(Phi_prev, x, A, y, direction)
% Performs the recurrent Phi (or Psi) matrix computation
% Phi = Phi_prev * (x'Ay).
% If direction is 'lr', computes Psi
% if direction is 'rl', computes Phi
% A can be empty, then only x'y is computed.

if (strcmp(direction, 'rl'))
  % Revert ranks to perform the right-to-left recursion
  x = permute(x, [3, 2, 1]);
  y = permute(y, [3, 2, 1]);
  if (~isempty(A))
    A = permute(A, [4, 2, 3, 1]);
  end
end

rx1 = size(x,1); n = size(x,2); rx2 = size(x,3);
ry1 = size(y,1); m = size(y,2); ry2 = size(y,3);
if (~isempty(A))
  ra1 = size(A,1); ra2 = size(A,4);
else
  ra1 = 1; ra2 = 1;
end

Phi = reshape(Phi_prev, [rx1*ra1, ry1]);
y = reshape(y, [ry1, m*ry2]);
Phi = Phi*y;	% complexity §\mcommentfont$\mathcal{O}(n  r_x r_A r_y^2)$§
Phi = reshape(Phi, [rx1, ra1, m, ry2]);
Phi = permute(Phi, [2, 3, 1, 4]);
if (~isempty(A))
  Phi = reshape(Phi, [ra1*m, rx1*ry2]);
  A = permute(A, [4, 2, 1, 3]);
  A = reshape(A, [ra2*n, ra1*m]);
  Phi = A*Phi;	% complexity §\mcommentfont$\mathcal{O}(n^2  r_x r_A^2 r_y)$§
  Phi = reshape(Phi, [ra2, n, rx1, ry2]);
end
Phi = permute(Phi, [3, 2, 1, 4]);
Phi = reshape(Phi, [rx1*n, ra2*ry2]);
x = reshape(x, [rx1*n, rx2]);
Phi = (x')*Phi;	% complexity §\mcommentfont$\mathcal{O}(n  r_x^2 r_A r_y)$§
if (~isempty(A))
  Phi = reshape(Phi, [rx2, ra2, ry2]);
end
end


function [y]=bfun3(Phi1,B1,B2,Phi2, x)
% Computes (Phi1 * B1 * B2 * Phi2)*x
% Phi1 is of sizes ry1, rB1, rx1
% B1 is of sizes rB1, k1, m1, rB2
% B2 is of sizes rB2, k2, m2, rB3
% Phi2 is of sizes ry3, rB3, rx3
ry1 = size(Phi1,1); ry3 = size(Phi2,1);
rx1 = size(Phi1,3); rx3 = size(Phi2,3);
rb1=size(B1,1); rb2=size(B1,4); rb3 = size(B2, 4);
m1 = size(B1,3); m2 = size(B2,3);
k1 = size(B1,2); k2 = size(B2,2);

y = reshape(x, rx1, m1*m2*rx3);
Phi1 = reshape(Phi1, ry1*rb1, rx1);
y = Phi1*y; % size ry1*rb1,m1*m2*rx3 % cplx rb*rx^3*m^2
y = reshape(y, ry1, rb1*m1, m2, rx3);
y = permute(y, [2, 1, 3, 4]);
y = reshape(y, rb1*m1, ry1*m2*rx3);
B1 = permute(B1, [2, 4, 1, 3]);
B1 = reshape(B1, k1*rb2, rb1*m1);
y = B1*y; % size k1*rb2, ry1*m2*rx3 % cplx rb^2*rx^2*n^3
y = reshape(y, k1, rb2, ry1, m2, rx3);
y = permute(y, [2, 4, 3, 1, 5]);
y = reshape(y, rb2*m2, ry1*k1*rx3);
B2 = permute(B2, [2, 4, 1, 3]);
B2 = reshape(B2, k2*rb3, rb2*m2);
y = B2*y; % size k2*rb3, ry1*k1*rx3 % cplx rb^2*rx^2*n^3
y = reshape(y, k2, rb3, ry1*k1, rx3);
y = permute(y, [2, 4, 3, 1]);
y = reshape(y, rb3*rx3, ry1*k1*k2);
Phi2 = reshape(Phi2, ry3, rb3*rx3);
y = Phi2*y; % size ry3, ry1*k1*k2 % cplx rb*rx^3*n^2
y = y.';
y = reshape(y, ry1*k1*k2*ry3, 1);
end
