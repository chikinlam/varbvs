% NOTES:
%
%   Options:
%     - tol
%     - maxiter
%     - verbose
%     - sigma
%     - q
%     - update_sigma
%     - update_q
%     - alpha
%     - mu
%     - q_penalty
%
%   Point out the connection to "mvash" (special case in which we have
%   individual-level data, and a linear regression model).
%
% TO DO:
%   * Provided detailed analysis summary with verbose = true.
%   * Add detailed comments describing function here.
%   * Set first (or zeroth) mixture component to be the "spike".
%
function fit = varbvsmix (X, Z, y, sa, labels, options)

  % Get the number of samples (n), variables (p) and mixture components (K).
  [n p] = size(X);
  K     = numel(sa);  
  
  % (1) CHECK INPUTS
  % ----------------
  % Input X must be single precision, and cannot be sparse.
  if issparse(X)
    error('Input X cannot be sparse');
  end
  if ~isa(X,'single')
    X = single(X);
  end

  % If input Z is not empty, it must be double precision, and must have as
  % many rows as X.
  if ~isempty(Z)
    if size(Z,1) ~= n
      error('Inputs X and Z do not match.');
    end
    Z = double(full(Z));
  end

  % Add intercept.
  Z    = [ones(n,1) Z];
  ncov = size(Z,2) - 1;

  % Input y must be a double-precision column vector with n elements.
  y = double(y(:));
  if length(y) ~= n
    error('Inputs X and y do not match.');
  end

  % Input sa must be a double-precision row vector.
  sa = double(sa(:))'; 
  
  % The labels must be a cell array with p elements, or an empty array.
  if nargin < 5
    labels = [];
  end
  if isempty(labels)
    labels = cellfun(@num2str,num2cell(1:p)','UniformOutput',false);
  else
    labels = labels(:);
    if (~iscell(labels) | length(labels) ~= p)
      error('labels must be a cell array with numel(labels) = size(X,2)');
    end
  end
  
  % (2) PROCESS OPTIONS
  % -------------------
  % If the 'options' input argument is not specified, all the options are
  % set to the defaults.
  if nargin < 6
    options = [];
  end
  
  % OPTIONS.TOL
  % Set the convergence tolerance of the co-ordinate ascent updates.
  if isfield(options,'tol')
    tol = options.tol;
  else
    tol = 1e-4;
  end

  % OPTIONS.MAXITER
  % Set the maximum number of inner-loop iterations.
  if isfield(options,'maxiter')
    maxiter = options.maxiter;
  else
    maxiter = 1e4;
  end
  if ~isfinite(maxiter)
    error('options.maxiter must be a finite number');
  end

  % OPTIONS.VERBOSE
  % Determine whether to output progress to the console.
  if isfield(options,'verbose')
    verbose = options.verbose;
  else
    verbose = true;
  end

  % OPTIONS.SIGMA
  % Get the initial estimate of the residual variance, if provided. By
  % default, the initial estimate is set to the sample variance of Y.
  if isfield(options,'sigma')
    sigma = double(options.sigma);
  else
    sigma = var(y);
  end

  % OPTIONS.Q
  % Get the initial estimate of the mixture weights, if provided. By
  % default, the initial estimate is set so that all the weights are equal.
  if isfield(options,'q')
    q = double(options.q(:))';
  else
    q = ones(1,K)/K;
  end

  % OPTIONS.Q_PENALTY
  % Specify the penalty term for estimating the mixture weights.
  if isfield(options,'q_penalty')
    q = double(options.q_penalty(:));
  else
    q_penalty = repmat(2,1,K);
  end
  
  % OPTIONS.UPDATE_SIGMA
  % Determine whether to update the residual variance parameter.
  if isfield(options,'update_sigma')
    update_sigma = options.update_sigma;
  else
    update_sigma = true;
  end

  % OPTIONS.UPDATE_Q
  % Determine whether to update the mixture weights.
  if isfield(options,'update_q')
    update_q = options.update_q;
  else
    update_q = true;
  end

  % OPTIONS.ALPHA
  % Set initial estimates of variational parameters 'alpha'. These
  % parameters are stored as a p x K matrix.
  if isfield(options,'alpha')
    alpha = double(options.alpha);
    if size(alpha,1) ~= p
      error('options.alpha must have one row for each variable (column of X)');
    end
    if size(alpha,2) ~= K
      error('options.alpha must have one column for each mixture component');
    end
  else
    alpha = rand(p,K);
    alpha = alpha ./ repmat(sum(alpha),p,1);
  end

  % OPTIONS.MU
  % Set initial estimates of variational parameters 'mu'. These
  % parameters are stored as a p x K matrix.
  if isfield(options,'mu')
    mu = double(options.mu);
    if size(mu,1) ~= p
      error('options.mu must have one row for each variable (column of X)');
    end
    if size(mu,2) == 1
      error('options.mu must have one column for each mixture component');
    end
  else
    mu = randn(p,K);
  end

  % (3) PREPROCESSING STEPS
  % -----------------------
  % Adjust the genotypes and phenotypes so that the linear effects of
  % the covariates are removed. This is equivalent to integrating out
  % the regression coefficients corresponding to the covariates with
  % respect to an improper, uniform prior; see Chipman, George and
  % McCulloch, "The Practical Implementation of Bayesian Model
  % Selection," 2001.
  %
  % Here I compute two quantities that are used here to remove linear
  % effects of the covariates (Z) on X and y, and later on (in function
  % "outerloop"), to efficiently compute estimates of the regression
  % coefficients for the covariates.
  SZy = (Z'*Z)\(Z'*y);
  SZX = (Z'*Z)\(Z'*X);
  if ncov == 0
    X = X - repmat(mean(X),length(y),1);
    y = y - mean(y);
  else

    % This should give the same result as centering the columns of X and
    % subtracting the mean from y when we have only one covariate, the
    % intercept.
    y = y - Z*SZy;
    X = X - Z*SZX;
  end

  % Provide a brief summary of the analysis.
  if verbose
    % TO DO.
  end
  
  % Compute a few useful quantities. Here, I calculate X'*y as (y'*X)' to
  % avoid computing the transpose of X, since X may be large.
  xy = double(y'*X)';
  d  = diagsq(X);
  Xr = double(X*sum(alpha.*mu,2));
  
  % For each variable and each mixture component, calculate s(i,k), the
  % variance of the regression coefficient conditioned on being drawn
  % from the kth mixture component.
  s = zeros(p,K);
  for i = 1:K
    s(:,i) = sigma*sa(i)./(sa(i)*d + 1);
  end
  
  % Initialize storage for outputs logw and err.
  logw = zeros(1,maxiter);
  err  = zeros(1,maxiter);
  
  % (4) MODEL FITTING - MAIN LOOP
  % -----------------------------
  % Repeat until convergence criterion is met, or until the maximum
  % number of iterations is reached.
  for iter = 1:maxiter

    % Save the current variational parameters and model parameters.
    alpha0 = alpha;
    mu0    = mu;
    s0     = s;
    sigma0 = sigma;
    q0     = q;

    % (4a) COMPUTE CURRENT VARIATIONAL LOWER BOUND
    % --------------------------------------------
    % Compute the lower bound to the marginal log-likelihood.
    logw0 = computevarlb(Z,Xr,d,y,sigma,sa,q,alpha,mu,s);
    
    % *** I'm up to here in testing this function using demo_mix.m ***
    
    % (4b) UPDATE VARIATIONAL APPROXIMATION
    % -------------------------------------
    % Run a forward or backward pass of the coordinate ascent updates.
    if mod(iter,2)
      i = 1:p;
    else
      i = p:-1:1;
    end
    [alpha mu Xr] = varbvsmixupdate(X,sigma,sa,q,xy,d,alpha,mu,Xr,i);

    % (4c) COMPUTE UPDATED VARIATIONAL LOWER BOUND
    % --------------------------------------------
    % Compute the lower bound to the marginal log-likelihood.
    log(iter) = calc_varlb(Xr,d,y,sigma,sa,q,alpha,mu,s);
    
    % (4d) UPDATE RESIDUAL VARIANCE
    % -----------------------------
    
    % Compute the maximum likelihood estimate of the residual variable
    % (sigma), if requested. Note that we must also recalculate the
    % variance of the regression coefficients when this parameter is
    % updated. 
    if update_sigma
      % TO DO.
    end
    
    % (4e) UPDATE MIXTURE WEIGHTS
    % ---------------------------
    % TO DO: Explain here what these lines of code do.
    if update_q
      % TO DO.
    end

    % (2f) CHECK CONVERGENCE
    % ----------------------
    
    % Print the status of the algorithm and check the convergence criterion.
    % Convergence is reached when the maximum difference between the
    % posterior inclusion probabilities at two successive iterations is less
    % than the specified tolerance, or when the variational lower bound has
    % decreased.
    err(iter) = max(max(abs(alpha - alpha0)));
    if verbose
      % TO DO.
    end
    if logw(iter) < logw0
      logw(iter) = logw0;
      err(iter)  = 0;
      sigma      = sigma0;
      q          = q0;
      alpha      = alpha0;
      mu         = mu0;
      s          = s0;
      break
    elseif err(iter) < tol
      break
    end
  end

  % Return the variational lower bound (logw) and "delta" in successive
  % iterates (err).
  logw = logw(1:iter);
  err  = err(1:iter);

% ----------------------------------------------------------------------
% Compute the lower bound to the marginal log-likelihood.
function I = computevarlb (Z, Xr, d, y, sigma, sa, q, alpha, mu, s)
  n = length(y);
  p = length(d);
  K = numel(sa);
  I = p/2 - n/2*log(2*pi*sigma) - logdet(Z'*Z)/2 ...
      - (norm(y - Xr)^2 + d'*betavarmix(alpha,mu,s))/(2*sigma);
  for i = 1:K
      I = I + sum(alpha(:,i)*log(q(i) + eps)) ...
            - alpha(:,i)'*log(alpha(:,i) + eps) ...
            + alpha(:,i)'*log(s(:,i)/(sigma*sa(i)))/2 ...
            - alpha(:,i)'*(s(:,i) + mu(:,i).^2)/(sigma*sa(i))/2;
  end