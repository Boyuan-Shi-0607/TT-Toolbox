function [y]=reort(u,uadd)
%[Y]=REORT(U,UADD)
%Faster (?) QR-decomposition of the matrix [u,v] by Golub-Kahan
%reorthogonalization
if (size(uadd,2)==0)
    y = u;
    return;
end;
if (size(u,1) == size(u,2) )
  y=u;
  return
end
if (size(u,2) + size(uadd,2) >= size(u,1) )
  uadd=uadd(:,size(u,1)-size(u,2));
end
radd=size(uadd,2);

mvr=u'*uadd; unew=uadd-u*mvr; 
reort_flag=true;
while (reort_flag )
    reort_flag=false;
    j=1;
%Nice vectorization!
norm_unew=sum(unew.^2,1); 
norm_uadd=sum(uadd.^2,1);
reort_flag=isempty(norm_unew <= 0.25*norm_uadd);
[unew,rv_not_used]=qr(unew,0); %Here it is ok.
if (reort_flag)
  su=u'*unew;
  uadd=unew;
  unew=unew-u*su; 
end
  
end
y=[u,unew];
return
end
